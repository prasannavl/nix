{
  backendLib,
  prefetchLib,
}: {
  lib,
  cfg,
  policy,
  catalog,
  stackName,
  stackReady,
  composeStack,
  defaultInstanceName,
  deviceFor,
  defaultLlamaCacheDirFor,
  users ? {},
  groups ? {},
}: let
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
    if hfOwnerName != null && users ? ${hfOwnerName}
    then users.${hfOwnerName}
    else {};
  hfOwnerGroupName = let
    configuredGroup = hfOwnerConfig.group or null;
  in
    if configuredGroup != null && configuredGroup != ""
    then configuredGroup
    else hfOwnerName;
  hfOwnerUid = hfOwnerConfig.uid or null;
  hfOwnerGid =
    if hfOwnerGroupName != null && groups ? ${hfOwnerGroupName}
    then groups.${hfOwnerGroupName}.gid or null
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
    && users ? ${hfOwnerName};
  hfOwnerGroupDeclared =
    hfOwnerGroupName
    != null
    && hfOwnerGroupName != ""
    && groups ? ${hfOwnerGroupName};
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
in {
  inherit
    ollamaDeployments
    llamaDeployments
    llamaDefaults
    resolvedRuntime
    resolvedDeploymentCacheDir
    resolvedIdleTimeout
    llamaDeploymentRecords
    llamaRuntimeNames
    runtimeRecords
    runtimeDeployments
    runtimePreserved
    resolvedCacheDir
    ollamaActive
    runtimeEnabled
    activeLlamaRuntimes
    llamaActiveFor
    depInstance
    instanceConfig
    deploymentServiceName
    deploymentUser
    deploymentPortNames
    deploymentPortName
    deploymentPortResolved
    deploymentPort
    llamaModelIdsByInstance
    deploymentModelIds
    backendProjections
    ollamaProjection
    llamaProjection
    runtimeProjection
    warmableRuntimeDeployments
    warmableRuntimeProjection
    warmableLlamaRuntimeNames
    ollamaRequired
    runtimeRequired
    runtimeModelPresets
    deploymentGlobalPreset
    legacyStateFile
    llamaStateName
    llamaLegacyStateFile
    allDeployments
    hfPrefetchResolution
    hfOwnerName
    hfOwnerConfig
    hfOwnerGroupName
    hfOwnerUid
    hfOwnerGid
    validPrefetchIdentityId
    hfCacheConfigured
    hfCachePathValid
    hfTokenPathValid
    hfOwnerDeclared
    hfOwnerGroupDeclared
    hfRequested
    hfPlanConfigValid
    hfPlan
    ollamaPlan
    llamaPlan
    modelPrefetchPlan
    ollamaModelsDirConfigured
    ollamaModelsDirValid
    llamaStorageAssignments
    managedStorageAssignments
    storageConflictPairs
    renderedStoragePaths
    aiStorageRoot
    aiStorageRootNeeded
    backendWorkerName
    ;
}
