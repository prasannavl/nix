let
  backendLib = import ./backends.nix;
  defaultCatalog = import ./catalog.nix;
  concat = builtins.concatStringsSep;
  isNonEmptyString = value: builtins.isString value && value != "";
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
  validEntry = entry:
    builtins.isAttrs entry
    && (entry ? id)
    && isNonEmptyString entry.id;
  validBackend = backend: entry:
    validEntry entry
    && backendLib.validBackendConfig (backendLib.backendConfig backend entry);
  validRuntime = entry:
    validBackend "llama" entry
    && backendLib.llamaRuntime entry != null;
  validPreset = entry: let
    config = backendLib.backendConfig "llama" entry;
    preset = config.preset or {};
    protected = ["alias" "embeddings" "hf"];
  in
    builtins.isAttrs preset
    && builtins.all
    (name: !(builtins.elem name protected) && builtins.isString preset.${name})
    (builtins.attrNames preset);
  diagnostic = code: message: {inherit code message;};
  optionalDiagnostic = condition: code: message:
    if condition
    then [(diagnostic code message)]
    else [];
  entriesFor = catalog: keys:
    builtins.map (key: catalog.${key}) (
      builtins.filter
      (key: catalog ? ${key} && validEntry catalog.${key})
      keys
    );
  refsFor = backend: entries:
    builtins.map
    (entry: (backendLib.backendConfig backend entry).ref)
    (builtins.filter (validBackend backend) entries);
  presetFor = embeddingId: entry: let
    config = backendLib.backendConfig "llama" entry;
  in
    {
      alias = entry.id;
      poll = "0";
    }
    // (config.preset or {})
    // (
      if embeddingId != null && entry.id == embeddingId
      then {embeddings = "true";}
      else {}
    );
in rec {
  catalogValidation = catalog: let
    keys = builtins.attrNames catalog;
    entries =
      builtins.map (key: {
        inherit key;
        value = catalog.${key};
      })
      keys;
    validId = entry:
      builtins.isAttrs entry.value
      && (entry.value ? id)
      && builtins.isString entry.value.id
      && entry.value.id != "";
    invalidEntryKeys = builtins.map (entry: entry.key) (builtins.filter (entry: !validId entry) entries);
    validEntries = builtins.filter validId entries;
    invalidBackendKeys = backend:
      builtins.map
      (entry: entry.key)
      (builtins.filter
        (entry:
          (entry.value ? ${backend})
          && !backendLib.validBackendConfig (backendLib.backendConfig backend entry.value))
        validEntries);
    invalidLlamaRuntimeKeys =
      builtins.map
      (entry: entry.key)
      (builtins.filter (entry: !backendLib.validLlamaRuntime entry.value) validEntries);
    ids = builtins.map (entry: entry.value.id) validEntries;
    uniqueIds = builtins.attrNames (builtins.listToAttrs (builtins.map (id: {
        name = id;
        value = true;
      })
      ids));
    duplicateIds =
      builtins.filter
      (id: builtins.length (builtins.filter (candidate: candidate == id) ids) > 1)
      uniqueIds;
    invalidOllamaKeys = invalidBackendKeys "ollama";
    invalidLlamaKeys = invalidBackendKeys "llama";
    errors =
      (
        if invalidEntryKeys == []
        then []
        else ["entries require a non-empty string id: ${builtins.concatStringsSep ", " invalidEntryKeys}"]
      )
      ++ (
        if invalidOllamaKeys == []
        then []
        else ["ollama references must be non-empty strings or attrsets with a non-empty string ref: ${builtins.concatStringsSep ", " invalidOllamaKeys}"]
      )
      ++ (
        if invalidLlamaKeys == []
        then []
        else ["llama references must be non-empty strings or attrsets with a non-empty string ref: ${builtins.concatStringsSep ", " invalidLlamaKeys}"]
      )
      ++ (
        if invalidLlamaRuntimeKeys == []
        then []
        else ["llama runtime names must be non-empty strings: ${builtins.concatStringsSep ", " invalidLlamaRuntimeKeys}"]
      )
      ++ (
        if duplicateIds == []
        then []
        else ["model ids must be unique: ${builtins.concatStringsSep ", " duplicateIds}"]
      );
  in {
    inherit duplicateIds errors invalidEntryKeys invalidLlamaKeys invalidLlamaRuntimeKeys invalidOllamaKeys;
  };

  checkedCatalog = catalog: let
    validation = catalogValidation catalog;
  in
    if validation.errors == []
    then catalog
    else throw "AI catalog is invalid: ${builtins.concatStringsSep "; " validation.errors}";

  # Catalog keys servable by the declared backends, in catalog order.
  #
  # A model is servable when its llama.cpp runtime is declared, or when it
  # carries an Ollama reference and an Ollama backend is declared. A declared
  # backend counts only when it has at least one deployment; entries without a
  # valid reference for that backend are ignored.
  servableModels = {
    catalog ? defaultCatalog,
    ollama ? false,
    runtimes ? {},
  }:
    builtins.filter
    (key: let
      entry = catalog.${key};
      membership = backendLib.configuredBackends {
        inherit entry ollama runtimes;
      };
    in
      membership.ollama || membership.llamaRuntime != null)
    (builtins.attrNames catalog);

  # Resolve model admission once from declaration-owned backend capabilities.
  # The result is total: malformed policy yields safe partial projections plus
  # structured diagnostics, not missing-attribute failures or side effects.
  resolvePolicy = {
    catalog ? defaultCatalog,
    models ? null,
    roles ? {},
    backends ? {
      ollama.deployments = [];
      llamaRouter.runtimes = {};
    },
  }: let
    catalogKeys = builtins.attrNames catalog;
    catalogEntries = entriesFor catalog catalogKeys;
    invalidEntryKeys = builtins.filter (key: !validEntry catalog.${key}) catalogKeys;
    invalidOllamaKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? ollama) && !validBackend "ollama" entry)
      catalogKeys;
    invalidLlamaKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? llama) && !validBackend "llama" entry)
      catalogKeys;
    invalidRuntimeKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validBackend "llama" entry && backendLib.llamaRuntime entry == null)
      catalogKeys;
    invalidPresetKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validRuntime entry && !validPreset entry)
      catalogKeys;
    duplicateIds = duplicateValues (builtins.map (entry: entry.id) catalogEntries);
    duplicateOllamaRefs = duplicateValues (refsFor "ollama" catalogEntries);

    runtimeConfigs = backends.llamaRouter.runtimes or {};
    runtimeNames = builtins.attrNames runtimeConfigs;
    ollamaAvailable = (backends.ollama.deployments or []) != [];
    membershipFor = entry:
      backendLib.configuredBackends {
        inherit entry;
        ollama = ollamaAvailable;
        runtimes = runtimeConfigs;
      };
    catalogRuntimeNames = builtins.attrNames (builtins.listToAttrs (builtins.map
      (entry: {
        name = backendLib.llamaRuntime entry;
        value = true;
      })
      (builtins.filter validRuntime catalogEntries)));
    llamaRefsByRuntime = builtins.listToAttrs (builtins.map
      (runtime: {
        name = runtime;
        value = refsFor "llama" (builtins.filter
          (entry: validRuntime entry && backendLib.llamaRuntime entry == runtime)
          catalogEntries);
      })
      catalogRuntimeNames);
    duplicateLlamaRefs =
      builtins.concatMap
      (runtime:
        builtins.map
        (ref: "${runtime}=${ref}")
        (duplicateValues llamaRefsByRuntime.${runtime}))
      catalogRuntimeNames;

    autoModels =
      builtins.filter
      (key: let
        membership = membershipFor catalog.${key};
      in
        validEntry catalog.${key}
        && (membership.ollama || membership.llamaRuntime != null))
      catalogKeys;
    resolvedModels =
      if models == null
      then autoModels
      else models;
    duplicateModelKeys = duplicateValues resolvedModels;
    unknownKeys = builtins.filter (key: !(catalog ? ${key})) resolvedModels;
    selectedEntries = entriesFor catalog resolvedModels;
    selected =
      builtins.map
      (entry: {
        inherit entry;
        membership = membershipFor entry;
      })
      selectedEntries;
    unknownRuntimeEntries =
      if runtimeNames == []
      then []
      else
        builtins.map (item: item.entry) (builtins.filter
          (item:
            !item.membership.ollama
            && item.membership.llamaRuntime == null
            && validRuntime item.entry
            && !(builtins.elem (backendLib.llamaRuntime item.entry) runtimeNames))
          selected);
    unknownRuntimeKeys = builtins.map (entry: entry.id) unknownRuntimeEntries;
    unservedKeys =
      builtins.map
      (item: item.entry.id)
      (builtins.filter
        (item:
          !item.membership.ollama
          && item.membership.llamaRuntime == null
          && !(builtins.elem item.entry unknownRuntimeEntries))
        selected);
    roleNames = builtins.attrNames roles;
    badRoles =
      builtins.filter
      (role: let
        key = roles.${role};
      in
        key
        != null
        && (
          !isNonEmptyString key
          || !(catalog ? ${key})
          || !(builtins.elem key resolvedModels)
          || !validEntry catalog.${key}
        ))
      roleNames;
    defaults =
      builtins.mapAttrs
      (_: key:
        if key == null
        then null
        else if isNonEmptyString key && catalog ? ${key} && builtins.elem key resolvedModels && validEntry catalog.${key}
        then catalog.${key}
        else null)
      roles;
    embeddingId =
      if defaults ? embedding && defaults.embedding != null
      then defaults.embedding.id
      else null;
    ollamaEntries = builtins.map (item: item.entry) (builtins.filter (item: item.membership.ollama) selected);
    runtimeEntries = runtime:
      builtins.map (item: item.entry) (builtins.filter (item: item.membership.llamaRuntime == runtime) selected);
    runtimeProjection = runtime: let
      entries = runtimeEntries runtime;
      refs = refsFor "llama" entries;
      aliases = builtins.map (entry: entry.id) entries;
      projectionSafe = duplicateValues refs == [] && duplicateValues aliases == [] && builtins.all validPreset entries;
    in {
      active = (runtimeConfigs.${runtime}.deployments or []) != [];
      models = builtins.map (entry: entry.id) entries;
      requiredModels = refs;
      modelPresets =
        if projectionSafe
        then
          builtins.listToAttrs (builtins.map (entry: {
              name = (backendLib.backendConfig "llama" entry).ref;
              value = presetFor embeddingId entry;
            })
            entries)
        else {};
    };
    diagnostics =
      optionalDiagnostic (invalidEntryKeys != []) "invalid-catalog-entry"
      "services.ai.catalog: entries require a non-empty string id: ${concat ", " invalidEntryKeys}"
      ++ optionalDiagnostic (invalidOllamaKeys != []) "invalid-ollama-reference"
      "services.ai.catalog: invalid Ollama references: ${concat ", " invalidOllamaKeys}"
      ++ optionalDiagnostic (invalidLlamaKeys != []) "invalid-llama-reference"
      "services.ai.catalog: invalid llama references: ${concat ", " invalidLlamaKeys}"
      ++ optionalDiagnostic (invalidRuntimeKeys != []) "invalid-llama-runtime"
      "services.ai.catalog: llama.runtime must be a non-empty string: ${concat ", " invalidRuntimeKeys}"
      ++ optionalDiagnostic (invalidPresetKeys != []) "invalid-llama-preset"
      "services.ai.catalog: llama presets require string values and cannot override alias, embeddings, or hf: ${concat ", " invalidPresetKeys}"
      ++ optionalDiagnostic (duplicateIds != []) "duplicate-model-id"
      "services.ai.catalog: client model ids must be unique: ${concat ", " duplicateIds}"
      ++ optionalDiagnostic (duplicateOllamaRefs != []) "duplicate-ollama-reference"
      "services.ai.catalog: Ollama references must be unique: ${concat ", " duplicateOllamaRefs}"
      ++ optionalDiagnostic (duplicateLlamaRefs != []) "duplicate-llama-reference"
      "services.ai.catalog: llama references must be unique within a runtime: ${concat ", " duplicateLlamaRefs}"
      ++ optionalDiagnostic (duplicateModelKeys != []) "duplicate-model-selection"
      "services.ai.models: catalog keys must be unique: ${concat ", " duplicateModelKeys}"
      ++ optionalDiagnostic (unknownKeys != []) "unknown-model"
      "services.ai: unknown catalog keys: ${concat ", " unknownKeys}"
      ++ optionalDiagnostic (unknownRuntimeKeys != []) "unknown-llama-runtime"
      "services.ai: selected models reference undeclared llama runtimes: ${concat ", " unknownRuntimeKeys}"
      ++ optionalDiagnostic (unservedKeys != []) "unserved-model"
      "services.ai: selected models have no deployed backend: ${concat ", " unservedKeys}"
      ++ optionalDiagnostic (badRoles != []) "invalid-role"
      "services.ai.roles: keys outside the managed model selection: ${concat ", " (builtins.map (role: "${role}=${
          if isNonEmptyString roles.${role}
          then roles.${role}
          else "<invalid>"
        }")
        badRoles)}";
  in {
    inherit catalog defaults diagnostics roles;
    valid = diagnostics == [];
    models = resolvedModels;
    selection = selectedEntries;
    ollama = {
      active = ollamaAvailable;
      models = builtins.map (entry: entry.id) ollamaEntries;
      requiredModels = refsFor "ollama" ollamaEntries;
    };
    runtimes = builtins.listToAttrs (builtins.map
      (runtime: {
        name = runtime;
        value = runtimeProjection runtime;
      })
      runtimeNames);
  };

  # OpenAI-compatible {served id -> upstream HF repo} map.
  catalogById = sourceCatalog: let
    catalog = checkedCatalog sourceCatalog;
    missingHf = builtins.filter (key: let
      hf = catalog.${key}.hf or null;
    in
      !builtins.isString hf || hf == "") (builtins.attrNames catalog);
  in
    if missingHf != []
    then throw "AI catalog entries require a non-empty string hf reference for catalogById: ${builtins.concatStringsSep ", " missingHf}"
    else
      builtins.listToAttrs
      (map (model: {
          name = model.id;
          value = model.hf;
        })
        (builtins.attrValues catalog));

  # Catalog ids flagged for default Web UI pinning.
  pinnedModelIds = sourceCatalog: let
    catalog = checkedCatalog sourceCatalog;
  in
    map (model: model.id) (builtins.filter (model: model.pinned or false) (builtins.attrValues catalog));

  # Project a stack service registry into per-service HTTP API records.
  mkServiceApis = {
    registry,
    services,
  }:
    builtins.mapAttrs
    (_: name: let
      baseUrl = registry.urlPrivateFor "http" name "http";
    in {
      port = registry.portFor name "http";
      inherit baseUrl;
      openAiBaseUrl = "${baseUrl}/v1";
    })
    services;

  # Resolve one host AI policy into the generic, repo-agnostic projection.
  #
  # `models = null` (the default) selects every model servable by the declared
  # backends; an explicit list is used verbatim. `defaults` maps each role to
  # its catalog entry so repositories can read `defaults.<role>.id` directly.
  # Service- and consumer-specific views (OpenAI proxy, Web UI, Graphiti,
  # storage layout) stay in the repository layer; the helpers above keep them
  # thin.
  mkProjection = {
    catalog ? defaultCatalog,
    models ? null,
    roles ? {},
    backends ? {
      ollama.deployments = [];
      llamaRouter.runtimes = {};
    },
    apiServices ? {},
  }: let
    policy = resolvePolicy {
      inherit backends catalog models roles;
    };
  in
    policy
    // {
      mkApi = registry:
        mkServiceApis {
          inherit registry;
          services = apiServices;
        };
      aiServices = {
        models = policy.models;
        roles = policy.roles;
        inherit backends;
      };
    };
}
