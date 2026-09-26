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
    selectAttrs deployment ["host" "instance" "lifecycle" "portName"];
  sanitizeLlamaDeployment = deployment:
    selectAttrs deployment [
      "cacheDir"
      "host"
      "idleTimeoutSeconds"
      "instance"
      "lifecycle"
      "models"
      "portName"
      "preservedModels"
      "runtime"
    ];
  sanitizeBackends = backends: {
    hf = selectAttrs (backends.hf or {}) ["cacheDir" "prefetch" "prefetchDefaults" "tokenFile" "user"];
    ollama =
      selectAttrs (backends.ollama or {}) ["modelsDir" "prefetch" "preservedModels"]
      // {
        deployments = builtins.map sanitizeDeployment (backends.ollama.deployments or []);
      };
    llamaRouter =
      selectAttrs (backends.llamaRouter or {}) ["prefetch"]
      // {
        defaults = selectAttrs (backends.llamaRouter.defaults or {}) ["cacheDir" "idleTimeoutSeconds" "models" "runtime"];
        deployments = builtins.map sanitizeLlamaDeployment (backends.llamaRouter.deployments or []);
      };
  };
  validEntry = entry:
    builtins.isAttrs entry
    && (entry ? id)
    && isNonEmptyString entry.id
    && (!(entry ? internal) || builtins.isBool entry.internal)
    && (!(entry ? artifacts) || builtins.isAttrs entry.artifacts);
  validBackend = backend: entry:
    validEntry entry
    && backendLib.validBackendConfig (backendLib.backendConfig backend entry);
  validLlamaBackend = entry: let
    config = backendLib.backendConfig "llama" entry;
  in
    validBackend "llama" entry
    && presetLib.validModelRef config.ref;
  validHfBackend = entry:
    validEntry entry && backendLib.validHfConfig (backendLib.backendConfig "hf" entry);
  validArtifact = artifact:
    builtins.isAttrs artifact
    && (artifact ? hf)
    && backendLib.validHfConfig (backendLib.backendConfig "hf" artifact);
  validRuntime = entry:
    validLlamaBackend entry
    && backendLib.validLlamaRuntimes entry;
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
    invalidHfKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? hf) && !validHfBackend entry)
      keys;
    invalidArtifactKeys =
      builtins.concatMap
      (key:
        builtins.map
        (artifact: "${key}.${artifact}")
        (builtins.filter
          (artifact: !validArtifact (backendLib.artifactsOf catalog.${key}).${artifact})
          (builtins.attrNames (backendLib.artifactsOf catalog.${key}))))
      keys;
    invalidLlamaKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validEntry entry && (entry ? llama) && !validLlamaBackend entry)
      keys;
    invalidRuntimeKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validLlamaBackend entry && !backendLib.validLlamaRuntimes entry)
      keys;
    invalidPresetKeys =
      builtins.filter
      (key: let entry = catalog.${key}; in validRuntime entry && !validPreset entry)
      keys;
    duplicateIds = duplicateValues (builtins.map (entry: entry.id) entries);
    duplicateOllamaRefs = duplicateValues (refsFor "ollama" entries);
    runtimeNames = builtins.attrNames (builtins.listToAttrs (builtins.concatMap
      (entry:
        builtins.map
        (runtime: {
          name = runtime;
          value = true;
        })
        (backendLib.llamaRuntimes entry))
      (builtins.filter validRuntime entries)));
    llamaRefsByRuntime = builtins.listToAttrs (builtins.map
      (runtime: {
        name = runtime;
        value = refsFor "llama" (builtins.filter
          (entry: validRuntime entry && builtins.elem runtime (backendLib.llamaRuntimes entry))
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
      "services.ai.catalog: entries require a non-empty string id, optional boolean internal flag, and optional artifacts attrset: ${concat ", " invalidEntryKeys}"
      ++ optionalDiagnostic (invalidOllamaKeys != []) "invalid-ollama-reference"
      "services.ai.catalog: Ollama references must be non-empty single-line strings: ${concat ", " invalidOllamaKeys}"
      ++ optionalDiagnostic (invalidHfKeys != []) "invalid-huggingface-reference"
      "services.ai.catalog: hf references require a non-empty ref plus optional non-empty revision and include strings: ${concat ", " invalidHfKeys}"
      ++ optionalDiagnostic (invalidArtifactKeys != []) "invalid-model-artifact"
      "services.ai.catalog: nested artifacts require a valid hf reference: ${concat ", " invalidArtifactKeys}"
      ++ optionalDiagnostic (invalidLlamaKeys != []) "invalid-llama-reference"
      "services.ai.catalog: llama references must be org/repo or org/repo:tag strings: ${concat ", " invalidLlamaKeys}"
      ++ optionalDiagnostic (invalidRuntimeKeys != []) "invalid-llama-runtime"
      "services.ai.catalog: llama.runtimes must be a non-empty unique list of lowercase runtime ids matching [a-z0-9][a-z0-9-]*: ${concat ", " invalidRuntimeKeys}"
      ++ optionalDiagnostic (invalidPresetKeys != []) "invalid-llama-preset"
      "services.ai.catalog: llama presets require a valid model alias plus non-empty single-line option names and values, and cannot override alias, embeddings, or hf: ${concat ", " invalidPresetKeys}"
      ++ optionalDiagnostic (duplicateIds != []) "duplicate-model-id"
      "services.ai.catalog: client model ids must be unique: ${concat ", " duplicateIds}"
      ++ optionalDiagnostic (duplicateOllamaRefs != []) "duplicate-ollama-reference"
      "services.ai.catalog: Ollama references must be unique: ${concat ", " duplicateOllamaRefs}"
      ++ optionalDiagnostic (duplicateLlamaRefs != []) "duplicate-llama-reference"
      "services.ai.catalog: llama references must be unique within a runtime: ${concat ", " duplicateLlamaRefs}";
  in {
    inherit diagnostics duplicateIds duplicateLlamaRefs duplicateOllamaRefs entries invalidArtifactKeys invalidEntryKeys invalidHfKeys invalidLlamaKeys invalidOllamaKeys invalidPresetKeys invalidRuntimeKeys;
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
      llamaRouter.deployments = [];
    },
  }: let
    catalogAnalysis = analyzeCatalog catalog;
    catalogKeys = builtins.attrNames catalog;
    llamaDefaults = backends.llamaRouter.defaults or {};
    declaredLlamaDeployments = backends.llamaRouter.deployments or [];
    llamaDeployments =
      builtins.map
      (deployment: {
        declaration = deployment;
        runtime = backendLib.effectiveDeploymentValue llamaDefaults deployment "runtime" "default";
        selection = backendLib.effectiveDeploymentValue llamaDefaults deployment "models" null;
      })
      declaredLlamaDeployments;
    validDeploymentRuntime = deployment: backendLib.validRuntimeName deployment.runtime;
    validDeploymentSelection = deployment:
      deployment.selection
      == null
      || (
        builtins.isList deployment.selection
        && builtins.all isNonEmptyString deployment.selection
      );
    deploymentLabel = deployment: let
      instance = deployment.declaration.instance or null;
    in
      if isNonEmptyString instance
      then instance
      else if validDeploymentRuntime deployment
      then "<${deployment.runtime}>"
      else "<invalid>";
    runtimeNames = builtins.attrNames (builtins.listToAttrs (builtins.map
      (deployment: {
        name = deployment.runtime;
        value = true;
      })
      (builtins.filter validDeploymentRuntime llamaDeployments)));
    ollamaAvailable = (backends.ollama.deployments or []) != [];
    deploymentAllows = key: entry: deployment:
      validDeploymentRuntime deployment
      && validDeploymentSelection deployment
      && validRuntime entry
      && builtins.elem deployment.runtime (backendLib.llamaRuntimes entry)
      && (deployment.selection == null || builtins.elem key deployment.selection);
    llamaDeploymentsFor = key: entry:
      builtins.filter (deployment: deploymentAllows key entry deployment) llamaDeployments;
    membershipFor = key: entry: {
      # Explicit admission may target an external HF-backed runtime such as
      # vLLM or SGLang, whose service command remains host-owned. Automatic
      # selection stays limited to modeled Ollama/llama.cpp deployments.
      hf = models != null && validHfBackend entry;
      ollama = ollamaAvailable && validBackend "ollama" entry;
      llamaDeployments = llamaDeploymentsFor key entry;
    };
    autoModels =
      builtins.filter
      (key: let
        entry = catalog.${key};
        membership = membershipFor key entry;
      in
        validEntry entry
        && (membership.ollama || membership.llamaDeployments != []))
      catalogKeys;
    resolvedModels =
      if models == null
      then autoModels
      else models;
    duplicateModelKeys = duplicateValues resolvedModels;
    unknownKeys = builtins.filter (key: !(catalog ? ${key})) resolvedModels;
    selected =
      builtins.concatMap
      (key:
        if catalog ? ${key} && validEntry catalog.${key}
        then let
          entry = catalog.${key};
        in [
          {
            inherit entry key;
            membership = membershipFor key entry;
          }
        ]
        else [])
      resolvedModels;
    selectedEntries = builtins.map (item: item.entry) selected;
    unknownRuntimeItems =
      builtins.filter
      (item:
        !item.membership.ollama
        && item.membership.llamaDeployments == []
        && !item.membership.hf
        && validRuntime item.entry
        && builtins.all
        (runtime: !(builtins.elem runtime runtimeNames))
        (backendLib.llamaRuntimes item.entry))
      selected;
    unknownRuntimeKeys = builtins.map (item: item.key) unknownRuntimeItems;
    unservedKeys = builtins.map (item: item.key) (builtins.filter
      (item:
        !item.membership.ollama
        && item.membership.llamaDeployments == []
        && !item.membership.hf
        && !(builtins.elem item unknownRuntimeItems))
      selected);
    declaredDeploymentModels =
      builtins.concatMap
      (deployment:
        if builtins.isList deployment.selection
        then builtins.map (key: {inherit deployment key;}) deployment.selection
        else [])
      llamaDeployments;
    duplicateDeploymentModels =
      builtins.concatMap
      (deployment:
        if !builtins.isList deployment.selection
        then []
        else
          builtins.map
          (key: "${deploymentLabel deployment}=${key}")
          (duplicateValues deployment.selection))
      llamaDeployments;
    unknownDeploymentModels =
      builtins.map
      (item: "${deploymentLabel item.deployment}=${item.key}")
      (builtins.filter (item: !(catalog ? ${item.key})) declaredDeploymentModels);
    incompatibleDeploymentModels =
      builtins.map
      (item: "${deploymentLabel item.deployment}=${item.key}")
      (builtins.filter
        (item:
          catalog ? ${item.key}
          && (
            !validRuntime catalog.${item.key}
            || !validDeploymentRuntime item.deployment
            || !(builtins.elem item.deployment.runtime (backendLib.llamaRuntimes catalog.${item.key}))
          ))
        declaredDeploymentModels);
    unadmittedDeploymentModels =
      if models == null
      then []
      else
        builtins.map
        (item: "${deploymentLabel item.deployment}=${item.key}")
        (builtins.filter
          (item: catalog ? ${item.key} && !(builtins.elem item.key resolvedModels))
          declaredDeploymentModels);
    invalidDeploymentRuntimes = builtins.map deploymentLabel (builtins.filter (deployment: !validDeploymentRuntime deployment) llamaDeployments);
    invalidDeploymentSelections = builtins.map deploymentLabel (builtins.filter (deployment: !validDeploymentSelection deployment) llamaDeployments);
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
    deploymentItems = deployment:
      builtins.filter
      (item: builtins.elem deployment item.membership.llamaDeployments)
      selected;
    projectionForItems = items: let
      entries = builtins.map (item: item.entry) items;
      refs = refsFor "llama" entries;
      aliases = builtins.map (entry: entry.id) entries;
      projectionSafe = duplicateValues refs == [] && duplicateValues aliases == [] && builtins.all validPreset entries;
    in {
      models = builtins.map (item: item.key) items;
      modelIds = aliases;
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
    deploymentProjection = deployment:
      {inherit (deployment) runtime;}
      // projectionForItems (deploymentItems deployment);
    runtimeEntries = runtime:
      builtins.filter
      (item:
        builtins.any
        (deployment: deployment.runtime == runtime)
        item.membership.llamaDeployments)
      selected;
    runtimeProjection = runtime: let
      deployments = builtins.filter (deployment: deployment.runtime == runtime) llamaDeployments;
    in
      {
        active = deployments != [];
        inherit deployments;
      }
      // projectionForItems (runtimeEntries runtime);
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
          ++ optionalDiagnostic (invalidDeploymentRuntimes != []) "invalid-llama-deployment-runtime"
          "services.ai.backends.llamaRouter.deployments: runtime must resolve to a lowercase id matching [a-z0-9][a-z0-9-]*: ${concat ", " invalidDeploymentRuntimes}"
          ++ optionalDiagnostic (invalidDeploymentSelections != []) "invalid-llama-deployment-models"
          "services.ai.backends.llamaRouter.deployments: models must resolve to null or a list of non-empty catalog keys: ${concat ", " invalidDeploymentSelections}"
          ++ optionalDiagnostic (duplicateDeploymentModels != []) "duplicate-llama-deployment-model"
          "services.ai.backends.llamaRouter.deployments: model selections must be unique per deployment: ${concat ", " duplicateDeploymentModels}"
          ++ optionalDiagnostic (unknownDeploymentModels != []) "unknown-llama-deployment-model"
          "services.ai.backends.llamaRouter.deployments: unknown catalog keys: ${concat ", " unknownDeploymentModels}"
          ++ optionalDiagnostic (incompatibleDeploymentModels != []) "incompatible-llama-deployment-model"
          "services.ai.backends.llamaRouter.deployments: models must support the deployment runtime: ${concat ", " incompatibleDeploymentModels}"
          ++ optionalDiagnostic (unadmittedDeploymentModels != []) "unadmitted-llama-deployment-model"
          "services.ai.backends.llamaRouter.deployments: explicit models must be admitted by services.ai.models: ${concat ", " unadmittedDeploymentModels}"
          ++ optionalDiagnostic (unknownRuntimeKeys != []) "unknown-llama-runtime"
          "services.ai: selected models have no deployment for any compatible llama runtime: ${concat ", " unknownRuntimeKeys}"
          ++ optionalDiagnostic (unservedKeys != []) "unserved-model"
          "services.ai: selected models have no deployed backend or explicit Hugging Face source: ${concat ", " unservedKeys}"
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
    llama.deployments = builtins.map deploymentProjection llamaDeployments;
    runtimes = builtins.listToAttrs (builtins.map
      (runtime: {
        name = runtime;
        value = runtimeProjection runtime;
      })
      runtimeNames);
  };

  # OpenAI-compatible {served id -> structured HF source} map. Public entries
  # without an HF source are valid for other backends and are omitted.
  hfSourcesById = sourceCatalog: let
    catalog = checkedCatalog sourceCatalog;
    hfKeys =
      builtins.filter
      (key: !(catalog.${key}.internal or false) && validHfBackend catalog.${key})
      (builtins.attrNames catalog);
  in
    builtins.listToAttrs (builtins.map
      (key: {
        name = catalog.${key}.id;
        value = backendLib.backendConfig "hf" catalog.${key};
      })
      hfKeys);

  hfSourceForId = sourceCatalog: id: let
    sources = hfSourcesById sourceCatalog;
  in
    sources.${id} or (throw "AI model ${id} has no Hugging Face source required by this consumer");

  # Compatibility view for callers that only need the repository reference.
  hfCatalogById = sourceCatalog:
    builtins.mapAttrs (_: source: source.ref) (hfSourcesById sourceCatalog);

  # Catalog ids flagged for default Web UI pinning.
  pinnedModelIds = sourceCatalog: let
    catalog = checkedCatalog sourceCatalog;
  in
    builtins.map (model: model.id) (builtins.filter (model: !(model.internal or false) && (model.pinned or false)) (builtins.attrValues catalog));

  # Consumer-facing endpoint view: the single source of truth for consumers.
  # Endpoints are ordered descriptors
  # `{ host?; port; instance?; device?; modelIds?; }`; an endpoint without
  # `host` uses `defaultHost`. `modelIds` is the exact ordered set of client
  # model IDs admitted to that endpoint. Each backend (`ollama`, `llama`)
  # yields ordered `endpoints`, native `urls` and OpenAI `openaiUrls`, a
  # `default` / `openaiDefault` primary, and `byDevice` / `openaiByDevice`
  # lookups keyed by device class (`rocm`/`nvidia`/`cpu`). llama.cpp also
  # carries `apiKeys`.
  mkConsumers = {
    defaultHost ? "127.0.0.1",
    ollamaEndpoints ? [],
    llamaEndpoints ? [],
    openaiApiKey ? "ollama",
  }: let
    # Endpoints are either fully resolved (`url`) or a `host`/`port` pair; an
    # absent or explicitly null `host` uses `defaultHost`.
    resolveHost = endpoint: let
      host = endpoint.host or null;
    in
      if host == null
      then defaultHost
      else host;
    resolveUrl = endpoint:
      if (endpoint.url or null) != null
      then endpoint.url
      else "http://${resolveHost endpoint}:${toString endpoint.port}";
    # The primary is required: a consumer that reaches for it must have the
    # backend deployed. Fail with one clear message instead of a null URL, so
    # no consumer ever guards or coerces a missing endpoint.
    primary = backend: urls:
      if urls == []
      then throw "AI consumers: no ${backend} endpoint is deployed on this host"
      else builtins.head urls;
    build = backend: endpoints: let
      resolved = builtins.map (endpoint:
        endpoint
        // (
          if (endpoint.url or null) != null
          then {}
          else {host = resolveHost endpoint;}
        )
        // {
          modelIds = endpoint.modelIds or [];
          url = resolveUrl endpoint;
        })
      endpoints;
      urls = builtins.map (endpoint: endpoint.url) resolved;
      openaiUrls = builtins.map (url: "${url}/v1") urls;
      # Device lookup is a list per class, so several endpoints of one class are
      # preserved instead of silently collapsed.
      byDeviceOf = valueOf:
        builtins.mapAttrs
        (_: entries: builtins.map valueOf entries)
        (builtins.groupBy
          (endpoint: endpoint.device)
          (builtins.filter (endpoint: (endpoint.device or null) != null) resolved));
    in {
      endpoints = resolved;
      inherit urls openaiUrls;
      byDevice = byDeviceOf (endpoint: endpoint.url);
      openaiByDevice = byDeviceOf (endpoint: "${endpoint.url}/v1");
      default = primary backend urls;
      openaiDefault = primary "${backend} (OpenAI)" openaiUrls;
    };
  in {
    ollama = build "ollama" ollamaEndpoints;
    llama =
      (build "llama.cpp" llamaEndpoints)
      // {
        apiKeys = builtins.map (_: openaiApiKey) llamaEndpoints;
      };
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
      llamaRouter.deployments = [];
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
