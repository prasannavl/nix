let
  backendLib = import ./backends.nix;
  defaultCatalog = import ./catalog.nix;
  presetLib = import ../llama-router/presets.nix;
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
  selectAttrs = source: names:
    builtins.listToAttrs (builtins.concatMap
      (name:
        if source ? ${name}
        then [
          {
            inherit name;
            value = source.${name};
          }
        ]
        else [])
      names);
  sanitizeDeployment = deployment:
    selectAttrs deployment ["instance" "portName" "lifecycle"];
  sanitizeBackends = backends: {
    ollama =
      selectAttrs (backends.ollama or {}) ["modelsDir" "preservedModels"]
      // {
        deployments = builtins.map sanitizeDeployment (backends.ollama.deployments or []);
      };
    llamaRouter.runtimes =
      builtins.mapAttrs
      (_: runtime:
        selectAttrs runtime ["cacheDir" "idleTimeoutSeconds" "preservedModels"]
        // {
          deployments = builtins.map sanitizeDeployment (runtime.deployments or []);
        })
      (backends.llamaRouter.runtimes or {});
  };
  validEntry = entry:
    builtins.isAttrs entry
    && (entry ? id)
    && isNonEmptyString entry.id;
  validBackend = backend: entry:
    validEntry entry
    && backendLib.validBackendConfig (backendLib.backendConfig backend entry);
  validLlamaBackend = entry: let
    config = backendLib.backendConfig "llama" entry;
  in
    validBackend "llama" entry
    && presetLib.validModelRef config.ref;
  validRuntime = entry:
    validLlamaBackend entry
    && backendLib.llamaRuntime entry != null;
  validPreset = entry: let
    config = backendLib.backendConfig "llama" entry;
    preset = config.preset or {};
    protected = ["alias" "embeddings" "hf"];
  in
    builtins.isAttrs preset
    && presetLib.validSectionName entry.id
    && presetLib.validOptions preset
    && builtins.all (name: !(builtins.elem name protected)) (builtins.attrNames preset);
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
    (builtins.filter
      (
        if backend == "llama"
        then validLlamaBackend
        else validBackend backend
      )
      entries);
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
  # Admit the catalog as one fleet-wide policy artifact. Diagnostics are
  # independent of a host selection so a malformed dormant entry cannot hide
  # until the first machine tries to serve it.
  analyzeCatalog = catalog: let
    keys = builtins.attrNames catalog;
    entries = entriesFor catalog keys;
    invalidEntryKeys = builtins.filter (key: !validEntry catalog.${key}) keys;
    invalidOllamaKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? ollama) && !validBackend "ollama" entry)
      keys;
    invalidLlamaKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? llama) && !validLlamaBackend entry)
      keys;
    invalidRuntimeKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validLlamaBackend entry && backendLib.llamaRuntime entry == null)
      keys;
    invalidPresetKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validRuntime entry && !validPreset entry)
      keys;
    duplicateIds = duplicateValues (builtins.map (entry: entry.id) entries);
    duplicateOllamaRefs = duplicateValues (refsFor "ollama" entries);
    runtimeNames = builtins.attrNames (builtins.listToAttrs (builtins.map
      (entry: {
        name = backendLib.llamaRuntime entry;
        value = true;
      })
      (builtins.filter validRuntime entries)));
    llamaRefsByRuntime = builtins.listToAttrs (builtins.map
      (runtime: {
        name = runtime;
        value = refsFor "llama" (builtins.filter
          (entry: validRuntime entry && backendLib.llamaRuntime entry == runtime)
          entries);
      })
      runtimeNames);
    duplicateLlamaRefs =
      builtins.concatMap
      (runtime:
        builtins.map
        (ref: "${runtime}=${ref}")
        (duplicateValues llamaRefsByRuntime.${runtime}))
      runtimeNames;
    diagnostics =
      optionalDiagnostic (invalidEntryKeys != []) "invalid-catalog-entry"
      "services.ai.catalog: entries require a non-empty string id: ${concat ", " invalidEntryKeys}"
      ++ optionalDiagnostic (invalidOllamaKeys != []) "invalid-ollama-reference"
      "services.ai.catalog: Ollama references must be non-empty single-line strings: ${concat ", " invalidOllamaKeys}"
      ++ optionalDiagnostic (invalidLlamaKeys != []) "invalid-llama-reference"
      "services.ai.catalog: llama references must be org/repo or org/repo:tag strings: ${concat ", " invalidLlamaKeys}"
      ++ optionalDiagnostic (invalidRuntimeKeys != []) "invalid-llama-runtime"
      "services.ai.catalog: llama.runtime must be a non-empty string: ${concat ", " invalidRuntimeKeys}"
      ++ optionalDiagnostic (invalidPresetKeys != []) "invalid-llama-preset"
      "services.ai.catalog: llama presets require a valid model alias plus non-empty single-line option names and values, and cannot override alias, embeddings, or hf: ${concat ", " invalidPresetKeys}"
      ++ optionalDiagnostic (duplicateIds != []) "duplicate-model-id"
      "services.ai.catalog: client model ids must be unique: ${concat ", " duplicateIds}"
      ++ optionalDiagnostic (duplicateOllamaRefs != []) "duplicate-ollama-reference"
      "services.ai.catalog: Ollama references must be unique: ${concat ", " duplicateOllamaRefs}"
      ++ optionalDiagnostic (duplicateLlamaRefs != []) "duplicate-llama-reference"
      "services.ai.catalog: llama references must be unique within a runtime: ${concat ", " duplicateLlamaRefs}";
  in {
    inherit diagnostics duplicateIds duplicateLlamaRefs duplicateOllamaRefs entries invalidEntryKeys invalidLlamaKeys invalidOllamaKeys invalidPresetKeys invalidRuntimeKeys;
    valid = diagnostics == [];
  };

  checkedCatalog = catalog: let
    analysis = analyzeCatalog catalog;
  in
    if analysis.valid
    then catalog
    else throw "AI catalog is invalid: ${concat "; " (builtins.map (entry: entry.message) analysis.diagnostics)}";

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
    catalogAnalysis = analyzeCatalog catalog;
    catalogKeys = builtins.attrNames catalog;
    catalogEntries = catalogAnalysis.entries;
    runtimeConfigs = backends.llamaRouter.runtimes or {};
    runtimeNames = builtins.attrNames runtimeConfigs;
    ollamaAvailable = (backends.ollama.deployments or []) != [];
    membershipFor = entry:
      backendLib.configuredBackends {
        inherit entry;
        ollama = ollamaAvailable;
        runtimes = runtimeConfigs;
      };
    autoModels =
      builtins.filter
      (key: let
        entry = catalog.${key};
        membership = membershipFor entry;
      in
        validEntry entry
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
    unknownRuntimeEntries = builtins.map (item: item.entry) (builtins.filter
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
          builtins.listToAttrs (builtins.map
            (entry: {
              name = (backendLib.backendConfig "llama" entry).ref;
              value = presetFor embeddingId entry;
            })
            entries)
        else {};
    };
    diagnostics =
      catalogAnalysis.diagnostics
      ++ (
        if !catalogAnalysis.valid
        then []
        else
          optionalDiagnostic (duplicateModelKeys != []) "duplicate-model-selection"
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
            badRoles)}"
      );
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
    then throw "AI catalog entries require a non-empty string hf reference for catalogById: ${concat ", " missingHf}"
    else
      builtins.listToAttrs (builtins.map
        (model: {
          name = model.id;
          value = model.hf;
        })
        (builtins.attrValues catalog));

  # Catalog ids flagged for default Web UI pinning.
  pinnedModelIds = sourceCatalog: let
    catalog = checkedCatalog sourceCatalog;
  in
    builtins.map (model: model.id) (builtins.filter (model: model.pinned or false) (builtins.attrValues catalog));

  # Consumer-facing endpoint lists. Callers pass the backend `ports`
  # projections, which already follow the host's deployment device order
  # (ROCm, NVIDIA, CPU), so the CPU fallback stays last. `host` is how the
  # consumer resolves the backends (containers use host.containers.internal).
  mkConsumers = {
    host ? "127.0.0.1",
    ollamaPorts ? [],
    llamaPorts ? [],
    openaiApiKey ? "ollama",
  }: {
    ollamaUrls = builtins.map (port: "http://${host}:${toString port}") ollamaPorts;
    openaiUrls = builtins.map (port: "http://${host}:${toString port}/v1") llamaPorts;
    openaiApiKeys = builtins.map (_: openaiApiKey) llamaPorts;
  };

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
  # `moduleConfig` is a complete, declaration-only services.ai input: it
  # includes the chosen catalog and strips all evaluated/read-only backend
  # outputs so another repository can safely consume it verbatim.
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
    policy = resolvePolicy {inherit backends catalog models roles;};
  in
    policy
    // {
      mkApi = registry:
        mkServiceApis {
          inherit registry;
          services = apiServices;
        };
      moduleConfig = {
        inherit (policy) catalog models roles;
        backends = sanitizeBackends backends;
      };
    };
}
