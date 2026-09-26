{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ai;
  inherit (lib) mkIf mkMerge mkOption types;

  defaultCatalog = import ./catalog.nix;
  backendLib = import ./backends.nix;
  prefetchLib = import ./prefetch.nix;
  projectionLib = import ./projection.nix;
  catalog = cfg.catalog;

  # Feed only declaration-owned capability fields to the pure resolver.
  # Evaluated backend outputs are deliberately excluded, avoiding a module
  # fixed point between policy admission and rendered runtime projections.
  policyBackends = {
    ollama.deployments = cfg.backends.ollama.deployments;
    llamaRouter = {
      inherit (cfg.backends.llamaRouter) defaults deployments;
    };
  };
  policy = projectionLib.resolvePolicy {
    inherit catalog;
    models = cfg.models;
    roles = cfg.roles;
    backends = policyBackends;
  };
  resolvedModels = policy.models;

  stackName = cfg.stack.name;
  stackReady = stackName != null;
  defaultLlamaCacheDirFor = runtime:
    if !stackReady
    then null
    else if runtime == "default"
    then "/var/lib/${stackName}/ai/llama-router"
    else "/var/lib/${stackName}/ai/llama-router-${runtime}";
  composeStack =
    if stackReady && config.services.podman-compose ? ${stackName}
    then config.services.podman-compose.${stackName}
    else {
      instances = {};
      servicePrefix = "";
      user = "root";
    };

  # Canonical podman-compose instance name for a backend deployment when the
  # deployment does not pin one explicitly.
  defaultInstanceName = {
    ollama = "ollama";
    llamaRouter = "llama-router";
  };
  deploymentOptions = {
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Podman-compose instance backing this deployment. Defaults to the
        backend's canonical instance name.
      '';
    };
    portName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Exposed-port name carrying the backend API. May be omitted when the
        compose instance exposes exactly one port.
      '';
    };
    lifecycle = mkOption {
      type = types.enum ["auto" "manual" "stopped"];
      default = "auto";
      description = ''
        auto: started at boot and kept up by the stack.
        manual: never auto-started; survives if started by hand.
        stopped: declaratively stopped; the stack keeps it down.
      '';
    };
    host = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Reachable host/address for this deployment as seen by consumers.
        null uses the consumer default host passed to
        `services.ai.consumersFor`. Set it when a deployment lives on a
        different host from its backend's other deployments.
      '';
    };
  };
  deploymentType = types.submodule {options = deploymentOptions;};
  runtimeNameType = types.addCheck types.str backendLib.validRuntimeName;
  llamaDeploymentType = types.submodule {
    options =
      deploymentOptions
      // {
        runtime = mkOption {
          type = types.nullOr runtimeNameType;
          default = null;
          description = "llama.cpp engine for this service; null inherits llamaRouter.defaults.runtime.";
        };
        cacheDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Model cache mounted by this service; null inherits the backend default or the runtime-derived path.";
        };
        models = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Exact catalog-key subset for this service; null inherits llamaRouter.defaults.models.";
        };
        idleTimeoutSeconds = mkOption {
          type = types.nullOr (types.either (types.enum [false]) types.ints.positive);
          default = null;
          description = "Per-service idle unload timeout; null inherits the backend default and false disables an inherited timeout.";
        };
        preservedModels = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Exact managed GGUF references to retain while relinquishing
            ownership in this deployment's runtime cache. Deployments sharing
            a runtime contribute to one preserved-model union.
          '';
        };
      };
  };
  hfPrefetchExpandedSelectionType = types.submodule {
    options = {
      base = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to download the model's base Hugging Face source.";
      };
      artifacts = mkOption {
        type = types.nullOr (types.either types.bool (types.listOf types.str));
        default = null;
        description = ''
          Nested artifact selection. null inherits the backend-wide artifacts
          default, true selects all artifacts, false selects none, and a list
          selects exactly the named artifacts.
        '';
      };
    };
  };
  hfPrefetchSelectionType = types.oneOf [
    types.bool
    (types.listOf types.str)
    hfPrefetchExpandedSelectionType
  ];

  # Ordered consumer-facing endpoint descriptor: resolved instance/API address,
  # optional host override, and exact admitted client model IDs.
  endpointType = types.submodule {
    options = {
      instance = mkOption {type = types.str;};
      port = mkOption {type = types.port;};
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      device = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      modelIds = mkOption {
        type = types.listOf types.str;
        description = "Exact ordered client model IDs admitted to this endpoint.";
      };
    };
  };

  # Device class from the deployment instance name (e.g. `llama-rocm`).
  deviceFor = instance:
    if lib.hasSuffix "-rocm" instance
    then "rocm"
    else if lib.hasSuffix "-nvidia" instance
    then "nvidia"
    else if lib.hasSuffix "-cpu" instance
    then "cpu"
    else null;

  consumerEndpointOptions = {
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
    device = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
    host = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
    port = mkOption {
      type = types.nullOr types.port;
      default = null;
    };
    modelIds = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Exact ordered client model IDs admitted to this endpoint.";
    };
    url = mkOption {type = types.str;};
  };
  consumerEndpointType = types.submodule {options = consumerEndpointOptions;};
  consumerLlamaEndpointType = types.submodule {
    options =
      consumerEndpointOptions
      // {
        runtime = mkOption {
          type = types.nullOr runtimeNameType;
          default = null;
        };
      };
  };
  consumerBackendOptionsFor = endpoint: {
    endpoints = mkOption {type = types.listOf endpoint;};
    urls = mkOption {type = types.listOf types.str;};
    openaiUrls = mkOption {type = types.listOf types.str;};
    default = mkOption {type = types.str;};
    openaiDefault = mkOption {type = types.str;};
    byDevice = mkOption {type = types.attrsOf (types.listOf types.str);};
    openaiByDevice = mkOption {type = types.attrsOf (types.listOf types.str);};
  };
  consumerBackendOptions = consumerBackendOptionsFor consumerEndpointType;
  consumerBackendType = types.submodule {options = consumerBackendOptions;};
  consumerLlamaType = types.submodule {
    options =
      consumerBackendOptionsFor consumerLlamaEndpointType
      // {apiKeys = mkOption {type = types.listOf types.str;};};
  };
  consumerType = types.submodule {
    options = {
      ollama = mkOption {type = consumerBackendType;};
      llama = mkOption {type = consumerLlamaType;};
    };
  };
  llamaDefaultsType = types.submodule {
    options = {
      runtime = mkOption {
        type = runtimeNameType;
        default = "default";
        description = "Default llama.cpp engine for deployments that do not select one.";
      };
      cacheDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Default model cache for deployments. null derives a distinct path
          from each deployment's runtime.
        '';
      };
      models = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Default deployment model filter; null selects every admitted model compatible with the runtime.";
      };
      idleTimeoutSeconds = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Default per-service idle unload timeout. null emits no global
          models.ini timeout; deployments may set a positive value or false to
          disable an inherited timeout.
        '';
      };
    };
  };
  llamaDeploymentInfoType = types.submodule {
    options = {
      runtime = mkOption {type = runtimeNameType;};
      cacheDir = mkOption {type = types.nullOr types.str;};
      models = mkOption {type = types.listOf types.str;};
      modelIds = mkOption {type = types.listOf types.str;};
      requiredModels = mkOption {type = types.listOf types.str;};
      modelPresets = mkOption {type = types.attrsOf (types.attrsOf types.str);};
      preservedModels = mkOption {type = types.listOf types.str;};
      idleTimeoutSeconds = mkOption {type = types.nullOr types.ints.positive;};
      serviceName = mkOption {type = types.str;};
      url = mkOption {type = types.nullOr types.str;};
      port = mkOption {type = types.nullOr types.port;};
    };
  };

  ollamaDeployments = cfg.backends.ollama.deployments;
  llamaDeployments = cfg.backends.llamaRouter.deployments;
  llamaDefaults = cfg.backends.llamaRouter.defaults;
  resolvedRuntime = deployment:
    backendLib.effectiveDeploymentValue llamaDefaults deployment "runtime" "default";
  resolvedDeploymentCacheDir = deployment:
    backendLib.effectiveDeploymentValue
    llamaDefaults
    deployment
    "cacheDir"
    (defaultLlamaCacheDirFor (resolvedRuntime deployment));
  resolvedIdleTimeout = deployment: let
    value = backendLib.effectiveDeploymentValue llamaDefaults deployment "idleTimeoutSeconds" null;
  in
    if value == false
    then null
    else value;
  llamaDeploymentRecords =
    builtins.genList
    (index: let
      deployment = builtins.elemAt llamaDeployments index;
    in {
      inherit deployment index;
      cacheDir = resolvedDeploymentCacheDir deployment;
      idleTimeoutSeconds = resolvedIdleTimeout deployment;
      policy = builtins.elemAt policy.llama.deployments index;
      runtime = resolvedRuntime deployment;
    })
    (builtins.length llamaDeployments);
  llamaRuntimeNames = builtins.attrNames (builtins.listToAttrs (builtins.map
    (record: {
      name = record.runtime;
      value = true;
    })
    (builtins.filter (record: backendLib.validRuntimeName record.runtime) llamaDeploymentRecords)));
  runtimeRecords = runtime: builtins.filter (record: record.runtime == runtime) llamaDeploymentRecords;
  runtimeDeployments = runtime: builtins.map (record: record.deployment) (runtimeRecords runtime);
  runtimePreserved = runtime:
    lib.unique (builtins.concatMap (record: record.deployment.preservedModels) (runtimeRecords runtime));
  resolvedCacheDir = runtime: let
    cacheDirs = lib.unique (builtins.map (record: record.cacheDir) (runtimeRecords runtime));
  in
    if cacheDirs == []
    then defaultLlamaCacheDirFor runtime
    else builtins.head cacheDirs;

  # A backend only emits anything once the stack identity is known and the
  # selection is fully resolvable; otherwise the assertions below report the
  # misconfiguration instead of crashing the evaluation.
  ollamaActive =
    stackReady
    && policy.valid
    && policy.ollama.active
    && ollamaProjection.user != null;
  # Which runtimes emit a reconciler/models.ini. Deployment presence only:
  # reading the compose projection here would make the models.ini assignment
  # (which feeds those instances) depend on itself.
  runtimeEnabled = runtime:
    stackReady
    && policy.valid
    && policy.runtimes.${runtime}.active;
  activeLlamaRuntimes = builtins.filter runtimeEnabled llamaRuntimeNames;
  llamaActiveFor = runtime: runtimeEnabled runtime && (runtimeProjection runtime).user != null;
  activeRuntimeBindings = builtins.map llamaBinding (builtins.filter llamaActiveFor activeLlamaRuntimes);

  depInstance = backend: deployment:
    if deployment.instance != null
    then deployment.instance
    else defaultInstanceName.${backend};
  instanceConfig = backend: deployment:
    composeStack.instances.${depInstance backend deployment} or {};
  deploymentServiceName = backend: deployment: let
    instance = instanceConfig backend deployment;
  in
    if (instance.serviceName or null) != null
    then instance.serviceName
    else "${composeStack.servicePrefix}${depInstance backend deployment}";
  deploymentUser = backend: deployment: let
    instance = instanceConfig backend deployment;
  in
    if (instance.user or null) != null
    then instance.user
    else composeStack.user;
  deploymentPortNames = backend: deployment:
    builtins.attrNames ((instanceConfig backend deployment).exposedPorts or {});
  deploymentPortName = backend: deployment: let
    names = deploymentPortNames backend deployment;
  in
    if deployment.portName != null
    then deployment.portName
    else if builtins.length names == 1
    then builtins.head names
    else null;
  deploymentPortResolved = backend: deployment: let
    instance = instanceConfig backend deployment;
    portName = deploymentPortName backend deployment;
  in
    portName != null && (instance.exposedPorts or {}) ? ${portName};
  deploymentPort = backend: deployment:
    if deploymentPortResolved backend deployment
    then (instanceConfig backend deployment).exposedPorts.${deploymentPortName backend deployment}.port
    else null;

  llamaModelIdsByInstance = builtins.listToAttrs (builtins.map
    (record: {
      name = depInstance "llamaRouter" record.deployment;
      value = record.policy.modelIds;
    })
    llamaDeploymentRecords);
  deploymentModelIds = backend: deployment:
    if backend == "ollama"
    then policy.ollama.models
    else llamaModelIdsByInstance.${depInstance backend deployment} or [];

  backendProjections = backend: deployments: let
    names = builtins.map (depInstance backend) deployments;
    autos = builtins.filter (deployment: deployment.lifecycle == "auto") deployments;
    users = lib.unique (builtins.map (deploymentUser backend) deployments);
    resolvedEndpoints = builtins.filter (entry: entry.port != null) (builtins.map (deployment:
      {
        name = depInstance backend deployment;
        port = deploymentPort backend deployment;
        host = deployment.host;
        modelIds = deploymentModelIds backend deployment;
      }
      // lib.optionalAttrs (backend == "llamaRouter") {
        runtime = resolvedRuntime deployment;
      })
    deployments);
  in {
    inherit names autos;
    user =
      if builtins.length users == 1
      then builtins.head users
      else null;
    serviceNames = builtins.map (deployment: "${deploymentServiceName backend deployment}.service") deployments;
    urls = builtins.map (entry: "http://127.0.0.1:${toString entry.port}") resolvedEndpoints;
    ports = builtins.map (entry: entry.port) resolvedEndpoints;
    portsByName = builtins.listToAttrs (builtins.map (entry: {
        inherit (entry) name;
        value = entry.port;
      })
      resolvedEndpoints);
    # Ordered consumer descriptors; `host` is null unless the deployment
    # overrides it, and `device` is derived from the instance name.
    endpoints = builtins.map (entry:
      {
        instance = entry.name;
        device = deviceFor entry.name;
        inherit (entry) port host modelIds;
      }
      // lib.optionalAttrs (entry ? runtime) {runtime = entry.runtime;})
    resolvedEndpoints;
    readyTarget =
      if autos == []
      then null
      else "${deploymentServiceName backend (builtins.head autos)}-ready.target";
  };

  ollamaProjection = backendProjections "ollama" ollamaDeployments;
  llamaProjection = backendProjections "llamaRouter" llamaDeployments;
  runtimeProjection = runtime: backendProjections "llamaRouter" (runtimeDeployments runtime);
  warmableRuntimeDeployments = runtime:
    builtins.filter (deployment: deployment.lifecycle != "stopped") (runtimeDeployments runtime);
  warmableRuntimeProjection = runtime:
    backendProjections "llamaRouter" (warmableRuntimeDeployments runtime);
  warmableLlamaRuntimeNames =
    builtins.filter (runtime: warmableRuntimeDeployments runtime != []) llamaRuntimeNames;

  ollamaRequired = policy.ollama.requiredModels;
  runtimeRequired = runtime: policy.runtimes.${runtime}.requiredModels;
  runtimeModelPresets = runtime: policy.runtimes.${runtime}.modelPresets;
  deploymentGlobalPreset = record:
    if record.idleTimeoutSeconds == null
    then {}
    else {
      sleep-idle-seconds = toString record.idleTimeoutSeconds;
    };

  legacyStateFile = backend: projection:
    if projection.user == null
    then null
    else "/var/lib/${projection.user}/ai/reconciler/${backend}.json";
  llamaStateName = runtime:
    if runtime == "default"
    then "llama-router.json"
    else "llama-router-${runtime}.json";
  llamaLegacyStateFile = runtime: projection:
    if runtime != "default"
    then null
    else legacyStateFile "llama-router" projection;

  ollamaReconciler = import ../ollama {inherit lib pkgs;};
  llamaReconciler = import ../llama-router {inherit lib pkgs;};

  deploymentModelsPresetIni = record:
    llamaReconciler.renderModelsPresetIni {
      globalPreset = deploymentGlobalPreset record;
      inherit (record.policy) modelPresets requiredModels;
    };

  ollamaBinding = ollamaReconciler.mkModelReconciler {
    backendServices = ollamaProjection.serviceNames;
    conditionUser = ollamaProjection.user;
    managedTarget = "${lib.strings.sanitizeDerivationName ollamaProjection.user}-managed";
    name = "${stackName}-ollama-models";
    ollamaUrls = ollamaProjection.urls;
    preservedModels = cfg.backends.ollama.preservedModels;
    readyTarget = ollamaProjection.readyTarget;
    requiredModels = ollamaRequired;
    legacyStateFile = legacyStateFile "ollama" ollamaProjection;
    timeoutReadySeconds = 3600;
  };

  llamaBinding = runtime: let
    projection = runtimeProjection runtime;
    name =
      if runtime == "default"
      then "${stackName}-llama-router-models"
      else "${stackName}-llama-router-${runtime}-models";
  in
    llamaReconciler.mkModelReconciler {
      backendServices = projection.serviceNames;
      conditionUser = projection.user;
      globalPreset = {};
      managedTarget = "${lib.strings.sanitizeDerivationName projection.user}-managed";
      modelPresets = runtimeModelPresets runtime;
      name = name;
      preservedModels = runtimePreserved runtime;
      readyTarget = projection.readyTarget;
      requiredModels = runtimeRequired runtime;
      routerUrls = projection.urls;
      legacyStateFile = llamaLegacyStateFile runtime projection;
      stateName = llamaStateName runtime;
      timeoutReadySeconds = 3600;
    };

  allDeployments =
    builtins.map (deployment: {
      backend = "ollama";
      runtime = null;
      inherit deployment;
    })
    ollamaDeployments
    ++ builtins.map (record: {
      backend = "llamaRouter";
      inherit (record) deployment runtime;
    })
    llamaDeploymentRecords;
  hfPrefetchResolution = prefetchLib.resolveHf {
    inherit catalog;
    artifactsByDefault = cfg.backends.hf.prefetchDefaults.artifacts;
    selections = cfg.backends.hf.prefetch;
  };
  hfOwnerName =
    if cfg.backends.hf.user != null
    then cfg.backends.hf.user
    else if stackReady
    then composeStack.user
    else null;
  hfOwnerConfig =
    if hfOwnerName != null && config.users.users ? ${hfOwnerName}
    then config.users.users.${hfOwnerName}
    else {};
  hfOwnerGroupName = let
    configuredGroup = hfOwnerConfig.group or null;
  in
    if configuredGroup != null && configuredGroup != ""
    then configuredGroup
    else hfOwnerName;
  hfOwnerUid = hfOwnerConfig.uid or null;
  hfOwnerGid =
    if hfOwnerGroupName != null && config.users.groups ? ${hfOwnerGroupName}
    then config.users.groups.${hfOwnerGroupName}.gid or null
    else null;
  validPrefetchIdentityId = value:
    builtins.isInt value
    && value >= 0
    && value <= 2147483647;
  hfCacheConfigured = cfg.backends.hf.cacheDir != null;
  hfCachePathValid = hfCacheConfigured && backendLib.validStoragePath cfg.backends.hf.cacheDir;
  hfTokenPathValid = cfg.backends.hf.tokenFile == null || backendLib.validStoragePath cfg.backends.hf.tokenFile;
  hfOwnerDeclared =
    hfOwnerName
    != null
    && hfOwnerName != ""
    && config.users.users ? ${hfOwnerName};
  hfOwnerGroupDeclared =
    hfOwnerGroupName
    != null
    && hfOwnerGroupName != ""
    && config.users.groups ? ${hfOwnerGroupName};
  hfRequested = hfPrefetchResolution.units != [];
  hfPlanConfigValid =
    hfCachePathValid
    && hfTokenPathValid
    && hfOwnerDeclared
    && hfOwnerGroupDeclared
    && validPrefetchIdentityId hfOwnerUid
    && validPrefetchIdentityId hfOwnerGid;
  hfPlan =
    if !hfRequested || !hfPlanConfigValid
    then []
    else
      prefetchLib.mkHfPlan {
        cacheDir = cfg.backends.hf.cacheDir;
        owner = {
          name = hfOwnerName;
          uid = hfOwnerUid;
          group = hfOwnerGroupName;
          gid = hfOwnerGid;
        };
        resolved = hfPrefetchResolution;
        tokenFile = cfg.backends.hf.tokenFile;
      };
  ollamaPlan = lib.optionals cfg.backends.ollama.prefetch (builtins.map (model: {
      id = "ollama:${model}";
      type = "ollama";
      inherit model;
      endpoints = ollamaProjection.urls;
      user = ollamaProjection.user;
      policy = "best-effort";
    })
    ollamaRequired);
  llamaPlan = lib.optionals cfg.backends.llamaRouter.prefetch (builtins.concatMap (runtime:
    builtins.map (model: {
      id = "llama:${runtime}:${model}";
      type = "llama";
      inherit model;
      endpoints = (warmableRuntimeProjection runtime).urls;
      user = (warmableRuntimeProjection runtime).user;
      policy = "best-effort";
    })
    (runtimeRequired runtime))
  warmableLlamaRuntimeNames);
  # Submit short llama.cpp cache requests before an Ollama pull can consume the
  # shared best-effort deadline. Required direct downloads still run first.
  modelPrefetchPlan = hfPlan ++ llamaPlan ++ ollamaPlan;
  modelPrefetchPlanFile = pkgs.writeText "ai-model-prefetch.json" (builtins.toJSON modelPrefetchPlan);
  modelPrefetchCachePreparer = pkgs.writeText "ai-model-prefetch-cache.py" (builtins.readFile ./model-prefetch-cache.py);
  modelPrefetchPackage = pkgs.writeShellApplication {
    name = "ai-model-prefetch-all";
    excludeShellChecks = [
      "SC1091"
      "SC2034"
    ];
    runtimeInputs =
      [
        pkgs.coreutils
        pkgs.curl
        pkgs.getent
        pkgs.jq
        pkgs.util-linux
      ]
      ++ lib.optionals (hfPlan != []) [
        pkgs.python3
        pkgs.python3Packages.huggingface-hub
      ];
    text = ''
      plan="''${AI_MODEL_PREFETCH_PLAN:-${modelPrefetchPlanFile}}"
      cache_preparer=${lib.escapeShellArg (
        if hfPlan != []
        then modelPrefetchCachePreparer
        else ""
      )}
      source ${./model-prefetch.sh}
      main "$@"
    '';
  };
  ollamaModelsDirConfigured = cfg.backends.ollama.modelsDir != null;
  ollamaModelsDirValid =
    !ollamaModelsDirConfigured
    || backendLib.validStoragePath cfg.backends.ollama.modelsDir;
  llamaStorageAssignments =
    builtins.map
    (runtime: {
      label = "llama.${runtime}";
      path = resolvedCacheDir runtime;
    })
    llamaRuntimeNames;
  managedStorageAssignments =
    lib.optional hfCachePathValid {
      label = "hf";
      path = cfg.backends.hf.cacheDir;
    }
    ++ lib.optional (ollamaModelsDirConfigured && ollamaModelsDirValid) {
      label = "ollama";
      path = cfg.backends.ollama.modelsDir;
    }
    ++ builtins.filter (assignment: backendLib.validStoragePath assignment.path) llamaStorageAssignments;
  storageConflictPairs =
    builtins.filter
    (pair: backendLib.storagePathsOverlap pair.left.path pair.right.path)
    (backendLib.indexedPairs managedStorageAssignments);
  renderedStoragePaths =
    lib.optional
    (hfCachePathValid && hfOwnerDeclared && hfOwnerGroupDeclared)
    cfg.backends.hf.cacheDir
    ++ lib.optional
    (ollamaProjection.user != null && ollamaModelsDirConfigured && ollamaModelsDirValid)
    cfg.backends.ollama.modelsDir
    ++ builtins.concatMap (runtime: let
      projection = runtimeProjection runtime;
      cacheDir = resolvedCacheDir runtime;
    in
      lib.optional
      (projection.user != null && backendLib.validStoragePath cacheDir)
      cacheDir)
    llamaRuntimeNames;
  aiStorageRoot =
    if stackReady
    then "/var/lib/${stackName}/ai"
    else null;
  aiStorageRootNeeded =
    aiStorageRoot
    != null
    && !(builtins.elem aiStorageRoot renderedStoragePaths)
    && builtins.any
    (path: path != aiStorageRoot && backendLib.storagePathContains aiStorageRoot path)
    renderedStoragePaths;
  backendWorkerName = backend: runtime:
    if backend == "ollama"
    then "${stackName}-ollama-models-pull"
    else if runtime == "default"
    then "${stackName}-llama-router-models-load"
    else "${stackName}-llama-router-${runtime}-models-load";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  backendReconcileCommand = backend: runtime: "-${systemctl} --user start --no-block ${backendWorkerName backend runtime}.service";
in {
  options.services.ai = {
    stack.name = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Podman-compose stack containing the AI backend instances. Deployment
        users, unit names, readiness targets, and API ports are derived from
        that stack rather than from this string.
      '';
    };

    catalog = mkOption {
      type = types.attrsOf types.attrs;
      default = defaultCatalog;
      description = ''
        Model catalog keyed by stable policy names. Entries require an id and
        declare their backend set through the reference fields they carry
        (ollama, llama, ...).
      '';
    };

    models = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        Managed catalog keys for this host, in deterministic selection order.
        Explicit lists preserve caller order; null uses sorted catalog-key
        order. This is the only admission list. Backends serve admitted models
        that carry their reference field; llama.cpp deployments may narrow
        placement but cannot expand admission. Explicit lists may also admit a
        Hugging Face-backed model for a host-owned runtime such as vLLM or
        SGLang. A model carrying no usable backend reference is a configuration
        error. null (the default) selects every model servable by the declared
        Ollama and llama.cpp deployments.
      '';
    };

    roles = {
      main = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Catalog key of the primary chat model, for consumers that want a policy pointer.";
      };
      smallTask = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Catalog key of the small/lightweight task model.";
      };
      embedding = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Catalog key of the embedding model; llama.cpp router presets flag it for embedding requests.";
      };
    };

    resolvedModels = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = ''
        Effective managed catalog keys after resolving the nullable models
        selection against configured backend deployments.
      '';
    };

    consumersFor = mkOption {
      type = types.functionTo consumerType;
      readOnly = true;
      description = ''
        Pure function of a consumer hostname (the default host for endpoints
        without their own `host`) returning the consumer view: per backend
        (`ollama`, `llama`) ordered `endpoints`, `urls`, a `default` primary
        URL, and `byDevice`; llama.cpp also carries `apiKeys`. The order
        follows each backend's deployment device order, so the CPU fallback is
        last.
      '';
    };

    backends = {
      hf = {
        cacheDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Shared HF_HOME used by prefetch and Hugging Face-backed runtimes such as vLLM and SGLang.";
        };
        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Owner of the shared Hugging Face cache; null inherits the compose stack user.";
        };
        tokenFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional runtime Hugging Face token file; its contents never enter the Nix store or process arguments.";
        };
        prefetch = mkOption {
          type = types.attrsOf hfPrefetchSelectionType;
          default = {};
          description = ''
            Catalog-keyed Hugging Face prefetch policy. `true` downloads the
            model and, by default, all nested artifacts; a list downloads the
            model plus exactly those artifact names; an empty list downloads only
            the model; false disables an inherited selection. An expanded
            selection independently controls `base` and `artifacts`, including
            artifact-only downloads with `base = false`. Set `artifacts = false`
            on an expanded per-model selection to exclude nested artifacts; an
            expanded selection must still select at least one unit. Use the
            literal `false` to disable a selection completely.
            Expanded selections compose across modules; scalar and list
            shorthands are atomic values. Prefetch is acquisition policy and is
            intentionally independent from services.ai.models admission.
          '';
        };
        prefetchDefaults.artifacts = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether model selections without an explicit nested-artifact choice
            also download all catalog artifacts.
          '';
        };
      };

      ollama = {
        prefetch = mkOption {
          type = types.bool;
          default = true;
          description = "Warm selected Ollama models through a running pre-activation backend when available.";
        };
        deployments = mkOption {
          type = types.listOf deploymentType;
          default = [];
          description = "Ollama container deployments serving this host's model selection.";
        };
        modelsDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Shared models directory mounted read-write into deployments:
            pulls run through the backend API, so blobs land here regardless
            of which deployment performs them. When set, a tmpfiles rule creates
            it with the deployment user's ownership.
          '';
        };
        preservedModels = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Exact managed tags to retain while relinquishing ownership. Models
            downloaded outside reconciliation need not be listed: they are
            unowned and always left untouched.
          '';
        };
        active = mkOption {
          type = types.bool;
          readOnly = true;
        };
        serviceNames = mkOption {
          type = types.listOf types.str;
          readOnly = true;
        };
        urls = mkOption {
          type = types.listOf types.str;
          readOnly = true;
        };
        ports = mkOption {
          type = types.listOf types.port;
          readOnly = true;
        };
        portsByName = mkOption {
          type = types.attrsOf types.port;
          readOnly = true;
        };
        endpoints = mkOption {
          type = types.listOf endpointType;
          readOnly = true;
        };
        readyTarget = mkOption {
          type = types.nullOr types.str;
          readOnly = true;
        };
        requiredModels = mkOption {
          type = types.listOf types.str;
          readOnly = true;
        };
      };

      llamaRouter = {
        prefetch = mkOption {
          type = types.bool;
          default = true;
          description = "Warm selected GGUF models through a running llama.cpp router when available.";
        };
        defaults = mkOption {
          type = llamaDefaultsType;
          default = {};
          description = ''
            Shared runtime, cache, model-filter, and idle-timeout defaults for
            llama.cpp deployments. Deployment values override these defaults.
          '';
        };
        deployments = mkOption {
          type = types.listOf llamaDeploymentType;
          default = [];
          description = ''
            llama.cpp service deployments. Each deployment selects one runtime
            and an optional catalog-key model subset; deployments of one runtime
            share its cache ownership and reconciler.
          '';
        };
        active = mkOption {
          type = types.bool;
          readOnly = true;
        };
        deploymentsInfo = mkOption {
          type = types.attrsOf llamaDeploymentInfoType;
          readOnly = true;
          description = ''
            Effective deployment projections keyed by compose instance: runtime,
            cache, selected catalog models, client model IDs, exact GGUF refs,
            presets, idle timeout, service name, URL, and port.
          '';
        };
      };
    };
  };

  config = mkMerge [
    {
      services.ai = {
        resolvedModels = resolvedModels;
        consumersFor = defaultHost:
          projectionLib.mkConsumers {
            inherit defaultHost;
            ollamaEndpoints = ollamaProjection.endpoints;
            llamaEndpoints = llamaProjection.endpoints;
          };
        backends.ollama = {
          active = ollamaDeployments != [];
          serviceNames = ollamaProjection.serviceNames;
          urls = ollamaProjection.urls;
          ports = ollamaProjection.ports;
          portsByName = ollamaProjection.portsByName;
          endpoints = ollamaProjection.endpoints;
          readyTarget = ollamaProjection.readyTarget;
          requiredModels = ollamaRequired;
        };
        backends.llamaRouter = {
          active = activeLlamaRuntimes != [];
          deploymentsInfo = builtins.listToAttrs (builtins.map (record: let
              deployment = record.deployment;
              port = deploymentPort "llamaRouter" deployment;
            in {
              name = depInstance "llamaRouter" deployment;
              value = {
                inherit port;
                inherit (record) cacheDir idleTimeoutSeconds runtime;
                inherit (record.policy) modelIds modelPresets models requiredModels;
                preservedModels = runtimePreserved record.runtime;
                serviceName = "${deploymentServiceName "llamaRouter" deployment}.service";
                url =
                  if port == null
                  then null
                  else "http://127.0.0.1:${toString port}";
              };
            })
            llamaDeploymentRecords);
        };
      };
    }

    {
      environment.systemPackages = lib.optional (modelPrefetchPlan != []) modelPrefetchPackage;
      system.systemBuilderCommands = lib.optionalString (modelPrefetchPlan != []) ''
        install -Dm0444 ${lib.escapeShellArg modelPrefetchPlanFile} "$out/share/ai/model-prefetch.json"
      '';
      system.build.aiModelPrefetchPlan = modelPrefetchPlanFile;
    }

    # Reconciler wiring. The default runtime keeps the historical
    # "<stack>-llama-router-models" unit names; extra runtimes nest under the
    # backend name so each engine reconciles its own cache independently. The
    # content keys stay static so the module system can resolve definition
    # paths before config is fixed; only values read the runtime list.
    (mkIf ollamaActive ollamaBinding)
    (mkIf
      (stackReady && policy.valid)
      {
        systemd.user.services = lib.mkMerge (builtins.map (binding: binding.systemd.user.services) activeRuntimeBindings);
        systemd.user.targets = lib.mkMerge (builtins.map (binding: binding.systemd.user.targets) activeRuntimeBindings);
        assertions = builtins.concatLists (builtins.map (binding: binding.assertions) activeRuntimeBindings);
      })
    (mkIf
      (stackReady && policy.valid)
      {
        services.podman-compose.${stackName}.instances = builtins.listToAttrs (builtins.map (record: {
            name = depInstance "llamaRouter" record.deployment;
            value.files."models.ini".text = deploymentModelsPresetIni record;
          })
          (builtins.filter (record: runtimeEnabled record.runtime) llamaDeploymentRecords));
      })

    # Deployment lifecycle: podman-compose instances keep owning container
    # definitions (image, devices, volumes); the module only projects
    # lifecycle decisions onto them.
    (mkIf
      stackReady
      {
        services.podman-compose.${stackName}.instances = builtins.listToAttrs (builtins.map ({
            backend,
            deployment,
            ...
          }: {
            name = depInstance backend deployment;
            value = {
              autoStart = mkIf (deployment.lifecycle == "manual") false;
              state = mkIf (deployment.lifecycle == "stopped") "stopped";
            };
          })
          allDeployments);
        systemd.user.services = builtins.listToAttrs (builtins.map ({
            backend,
            runtime,
            deployment,
          }: {
            name = deploymentServiceName backend deployment;
            value.serviceConfig.ExecStartPost = lib.mkAfter [(backendReconcileCommand backend runtime)];
          })
          allDeployments);
      })

    # Storage locations. Container files bind-mount these paths; tmpfiles
    # guarantees they exist with stack ownership. Emit the conventional AI
    # parent only when an actual managed path is nested below it.
    {
      systemd.tmpfiles.rules = lib.unique (
        lib.optional
        aiStorageRootNeeded
        "d ${aiStorageRoot} 0755 ${composeStack.user} ${composeStack.user} -"
        ++ lib.optional
        (hfCachePathValid && hfOwnerDeclared && hfOwnerGroupDeclared)
        "d ${cfg.backends.hf.cacheDir} 0750 ${hfOwnerName} ${hfOwnerGroupName} -"
        ++ lib.optional
        (ollamaProjection.user != null && ollamaModelsDirConfigured && ollamaModelsDirValid)
        "d ${cfg.backends.ollama.modelsDir} 0755 ${ollamaProjection.user} ${ollamaProjection.user} -"
        ++ builtins.concatMap (runtime: let
          projection = runtimeProjection runtime;
          cacheDir = resolvedCacheDir runtime;
        in
          lib.optional
          (projection.user != null && backendLib.validStoragePath cacheDir)
          "d ${cacheDir} 0755 ${projection.user} ${projection.user} -")
        llamaRuntimeNames
      );
    }

    # Eval-time invariants.
    {
      assertions = let
        anyBackends = ollamaDeployments != [] || llamaDeployments != [];
        deploymentNames = builtins.map ({
          backend,
          deployment,
          ...
        }:
          depInstance backend deployment)
        allDeployments;
        deploymentPorts = builtins.filter (port: port != null) (builtins.map ({
          backend,
          deployment,
          ...
        }:
          deploymentPort backend deployment)
        allDeployments);
        deploymentServiceNames = builtins.map ({
          backend,
          deployment,
          ...
        }:
          deploymentServiceName backend deployment)
        allDeployments;
        inconsistentCacheRuntimes =
          builtins.filter
          (runtime:
            builtins.length (lib.unique (builtins.map (record: record.cacheDir) (runtimeRecords runtime))) != 1)
          llamaRuntimeNames;
        invalidLlamaCacheDeployments =
          builtins.map
          (record: depInstance "llamaRouter" record.deployment)
          (builtins.filter
            (record: !backendLib.validStoragePath record.cacheDir)
            llamaDeploymentRecords);
        renderedStorageConflicts =
          builtins.map
          (pair: "${pair.left.label}=${pair.left.path} <-> ${pair.right.label}=${pair.right.path}")
          storageConflictPairs;
        instanceDefined = backend: deployment:
          stackReady
          && composeStack.instances ? ${depInstance backend deployment}
          && ((instanceConfig backend deployment).source or null) != null;
        backendUsersValid = projection: projection.user != null;
        inherit
          (hfPrefetchResolution)
          duplicateArtifacts
          emptyModels
          unknownArtifacts
          unknownModels
          ;
      in
        builtins.map
        (entry: {
          assertion = false;
          inherit (entry) message;
        })
        policy.diagnostics
        ++ [
          {
            assertion = !anyBackends || stackReady;
            message = "services.ai: backends are enabled but services.ai.stack.name is not set (configure it in the stack's common host profile).";
          }
          {
            assertion = builtins.length (lib.unique deploymentNames) == builtins.length deploymentNames;
            message = "services.ai: deployment instance names must be unique across backends and runtimes.";
          }
          {
            assertion = builtins.length (lib.unique deploymentServiceNames) == builtins.length deploymentServiceNames;
            message = "services.ai: resolved deployment service names must be unique across backends and runtimes.";
          }
          {
            assertion = builtins.length (lib.unique deploymentPorts) == builtins.length deploymentPorts;
            message = "services.ai: deployment API ports must be unique across backends and runtimes.";
          }
          {
            assertion = storageConflictPairs == [];
            message = "services.ai: managed backend storage paths must be pairwise non-overlapping: ${lib.concatStringsSep ", " renderedStorageConflicts}";
          }
          {
            assertion = inconsistentCacheRuntimes == [];
            message = "services.ai.backends.llamaRouter.deployments: deployments sharing a runtime must resolve to one cacheDir: ${lib.concatStringsSep ", " inconsistentCacheRuntimes}";
          }
          {
            assertion = invalidLlamaCacheDeployments == [];
            message = "services.ai.backends.llamaRouter.deployments: cacheDir must resolve to a canonical safe absolute path: ${lib.concatStringsSep ", " invalidLlamaCacheDeployments}";
          }
          {
            assertion = ollamaModelsDirValid;
            message = "services.ai.backends.ollama.modelsDir must be a canonical safe absolute path when configured.";
          }
          {
            assertion = ollamaDeployments == [] || backendUsersValid ollamaProjection;
            message = "services.ai.backends.ollama: deployments must resolve to one systemd user.";
          }
          {
            assertion = unknownModels == [];
            message = "services.ai.backends.hf.prefetch: unknown catalog keys: ${lib.concatStringsSep ", " unknownModels}";
          }
          {
            assertion = emptyModels == [];
            message = "services.ai.backends.hf.prefetch: selections must resolve to a base hf source or nested hf artifact: ${lib.concatStringsSep ", " emptyModels}";
          }
          {
            assertion = unknownArtifacts == [];
            message = "services.ai.backends.hf.prefetch: unknown nested artifacts: ${lib.concatStringsSep ", " unknownArtifacts}";
          }
          {
            assertion = duplicateArtifacts == [];
            message = "services.ai.backends.hf.prefetch: artifact selections must be unique: ${lib.concatStringsSep ", " duplicateArtifacts}";
          }
          {
            assertion = !hfRequested || hfCacheConfigured;
            message = "services.ai.backends.hf.cacheDir must be configured when Hugging Face artifacts are selected for prefetch.";
          }
          {
            assertion = !hfCacheConfigured || hfCachePathValid;
            message = "services.ai.backends.hf.cacheDir must be a canonical safe absolute non-root path when configured.";
          }
          {
            assertion = !hfCacheConfigured || (hfOwnerName != null && hfOwnerName != "");
            message = "services.ai.backends.hf.user or the compose stack user must name the Hugging Face cache owner when cacheDir is configured.";
          }
          {
            assertion = !hfCacheConfigured || hfOwnerName == null || hfOwnerName == "" || hfOwnerDeclared;
            message = "the Hugging Face cache owner must name a declared users.users entry when cacheDir is configured.";
          }
          {
            assertion = !hfCacheConfigured || !hfOwnerDeclared || hfOwnerGroupDeclared;
            message = "the Hugging Face cache owner group must name a declared users.groups entry when cacheDir is configured.";
          }
          {
            assertion = !hfRequested || !hfCacheConfigured || !hfOwnerDeclared || validPrefetchIdentityId hfOwnerUid;
            message = "the Hugging Face cache owner must resolve to a fixed numeric users.users.<name>.uid in the supported 0..2147483647 range when artifacts are selected.";
          }
          {
            assertion = !hfRequested || !hfCacheConfigured || !hfOwnerGroupDeclared || validPrefetchIdentityId hfOwnerGid;
            message = "the Hugging Face cache owner group must resolve to a fixed numeric users.groups.<group>.gid in the supported 0..2147483647 range when artifacts are selected.";
          }
          {
            assertion = hfTokenPathValid;
            message = "services.ai.backends.hf.tokenFile must be a canonical safe absolute non-root path.";
          }
        ]
        ++ builtins.map (runtime: {
          assertion = runtimeDeployments runtime == [] || backendUsersValid (runtimeProjection runtime);
          message = "services.ai.backends.llamaRouter.deployments: runtime ${runtime} must resolve to one systemd user.";
        })
        llamaRuntimeNames
        ++ builtins.map ({
          backend,
          deployment,
          ...
        }: {
          assertion = !stackReady || !anyBackends || instanceDefined backend deployment;
          message = "services.ai.backends.${backend}: deployment ${depInstance backend deployment} has no matching podman-compose instance.";
        })
        allDeployments
        ++ builtins.map ({
          backend,
          deployment,
          ...
        }: {
          assertion = !instanceDefined backend deployment || deploymentPortResolved backend deployment;
          message = "services.ai.backends.${backend}: deployment ${depInstance backend deployment} must select an existing exposed API port (set portName when the instance exposes more than one).";
        })
        allDeployments;
    }
  ];
}
