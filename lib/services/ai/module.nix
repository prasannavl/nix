{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ai;
  inherit (lib) mkIf mkMerge mkOption types;

  aiLib = import ./default.nix {inherit lib;};
  catalog = cfg.catalog;

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
  deploymentType = types.submodule {
    options = {
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
    };
  };

  # A named llama.cpp engine. Each runtime owns its deployments, cache, and
  # reconciler, so a fork engine can never inherit another engine's models.
  # Catalog entries opt in with `llama.runtime`; `default` (upstream llama.cpp)
  # is the default engine.
  llamaRuntimeType = types.submodule ({...}: {
    options = {
      deployments = mkOption {
        type = types.listOf deploymentType;
        default = [];
        description = "Container deployments running this llama.cpp engine.";
      };
      cacheDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Download cache for this engine's GGUF files. null selects the
          per-runtime default (see runtimesInfo.<name>.cacheDir). Runtimes get
          a distinct directory so one engine's cache scan cannot surface
          another engine's models.
        '';
      };
      idleTimeoutSeconds = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Seconds of continuous model idleness after which this engine's
          workers release their resident model and KV cache
          (llama.cpp --sleep-idle-seconds). Emitted as the models.ini [*]
          section so it reaches managed and cache-scanned models alike.
          null keeps models resident until LRU eviction.
        '';
      };
      preservedModels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Exact managed GGUF references to retain while relinquishing
          ownership. Ad-hoc cache entries are unowned and always untouched.
        '';
      };
    };
  });

  ollamaDeployments = cfg.backends.ollama.deployments;
  llamaRuntimes = cfg.backends.llamaRouter.runtimes;
  llamaRuntimeNames = builtins.attrNames llamaRuntimes;
  llamaRuntimeCfg = runtime: llamaRuntimes.${runtime};
  runtimeDeployments = runtime: (llamaRuntimeCfg runtime).deployments;
  # Resolved per-runtime cache dir. The option default is null so option
  # evaluation never reads config; the effective path is derived here.
  resolvedCacheDir = runtime: let
    cacheDir = (llamaRuntimeCfg runtime).cacheDir;
  in
    if cacheDir != null
    then cacheDir
    else defaultLlamaCacheDirFor runtime;

  # services.ai.models is the single selection list. A model joins a backend
  # exactly when it carries that backend's reference field, so the catalog
  # schema itself records the backend set; there are no per-backend overrides.
  selectedEntries = builtins.map (key: let
    entry = catalog.${key} or null;
  in
    if builtins.isAttrs entry && (entry ? id) && builtins.isString entry.id
    then entry
    else {
      id = key;
      missing = true;
    })
  cfg.models;
  unknownKeys = aiLib.missingKeysFrom catalog cfg.models;
  invalidCatalogKeys = builtins.filter (key: let
    entry = catalog.${key} or null;
  in
    entry != null && (!(builtins.isAttrs entry) || !(entry ? id) || !(builtins.isString entry.id)))
  cfg.models;
  selectionValid = unknownKeys == [] && invalidCatalogKeys == [];
  hasBackend = backend: entry: aiLib.missingRefs backend [entry] == [];
  selectedFor = backend: builtins.filter (hasBackend backend) selectedEntries;
  ollamaSelected = selectedFor "ollama";
  llamaSelected = selectedFor "llama";
  unserved =
    if selectionValid
    then builtins.filter (entry: !(hasBackend "ollama" entry) && !(hasBackend "llama" entry)) selectedEntries
    else [];
  unknownLlamaRuntime =
    if selectionValid && llamaRuntimeNames != []
    then builtins.filter (entry: !(builtins.elem (aiLib.llamaRuntime entry) llamaRuntimeNames)) llamaSelected
    else [];

  # A backend only emits anything once the stack identity is known and the
  # selection is fully resolvable; otherwise the assertions below report the
  # misconfiguration instead of crashing the evaluation.
  ollamaActive =
    stackReady
    && ollamaDeployments != []
    && selectionValid
    && ollamaProjection.user != null;
  # Which runtimes emit a reconciler/models.ini. Deployment presence only:
  # reading the compose projection here would make the models.ini assignment
  # (which feeds those instances) depend on itself.
  runtimeEnabled = runtime:
    stackReady
    && runtimeDeployments runtime != []
    && selectionValid;
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
    else 1;

  backendProjections = backend: deployments: let
    names = builtins.map (depInstance backend) deployments;
    autos = builtins.filter (deployment: deployment.lifecycle == "auto") deployments;
    users = lib.unique (builtins.map (deploymentUser backend) deployments);
  in {
    inherit names autos;
    user =
      if builtins.length users == 1
      then builtins.head users
      else null;
    serviceNames = builtins.map (deployment: "${deploymentServiceName backend deployment}.service") deployments;
    urls = builtins.map (deployment: "http://127.0.0.1:${toString (deploymentPort backend deployment)}") deployments;
    ports = builtins.map (deploymentPort backend) deployments;
    portsByName = builtins.listToAttrs (builtins.map (deployment: {
        name = depInstance backend deployment;
        value = deploymentPort backend deployment;
      })
      deployments);
    readyTarget =
      if autos == []
      then null
      else "${deploymentServiceName backend (builtins.head autos)}-ready.target";
  };

  ollamaProjection = backendProjections "ollama" ollamaDeployments;
  runtimeProjection = runtime: backendProjections "llamaRouter" (runtimeDeployments runtime);

  embeddingId =
    if cfg.roles.embedding == null
    then null
    else (catalog.${cfg.roles.embedding} or {id = null;}).id;
  ollamaRequired =
    if selectionValid
    then aiLib.projectModels "ollama" ollamaSelected
    else [];
  runtimeSelected = runtime: builtins.filter (entry: aiLib.llamaRuntime entry == runtime) llamaSelected;
  runtimeRequired = runtime:
    if selectionValid
    then aiLib.projectModels "llama" (runtimeSelected runtime)
    else [];
  runtimeModelPresets = runtime:
    if selectionValid
    then aiLib.llamaPresets embeddingId (runtimeSelected runtime)
    else {};
  # Router-wide preset defaults (the models.ini [*] section). llama.cpp
  # cascades these onto every model child, including cache-scanned entries,
  # so idle sleep applies to managed and ad-hoc models alike.
  runtimeGlobalPreset = runtime:
    if (llamaRuntimeCfg runtime).idleTimeoutSeconds == null
    then {}
    else {
      sleep-idle-seconds = toString (llamaRuntimeCfg runtime).idleTimeoutSeconds;
    };

  allUsers = builtins.filter (user: user != null) (
    lib.optional (ollamaProjection.user != null) ollamaProjection.user
    ++ builtins.map (runtime: (runtimeProjection runtime).user) llamaRuntimeNames
  );
  aiStorageUser =
    if allUsers == []
    then null
    else builtins.head (lib.unique allUsers);

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
      globalPreset = runtimeGlobalPreset runtime;
      managedTarget = "${lib.strings.sanitizeDerivationName projection.user}-managed";
      modelPresets = runtimeModelPresets runtime;
      name = name;
      preservedModels = (llamaRuntimeCfg runtime).preservedModels;
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
    ++ builtins.concatMap (runtime:
      builtins.map (deployment: {
        backend = "llamaRouter";
        inherit runtime deployment;
      }) (runtimeDeployments runtime))
    llamaRuntimeNames;
  backendWorkerName = backend: runtime:
    if backend == "ollama"
    then "${stackName}-ollama-models-pull"
    else if runtime == "default"
    then "${stackName}-llama-router-models-load"
    else "${stackName}-llama-router-${runtime}-models-load";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  backendReconcileCommand = backend: runtime: "-${systemctl} --user restart --no-block ${backendWorkerName backend runtime}.service";
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
      default = aiLib.catalog;
      description = ''
        Model catalog keyed by stable policy names. Entries require an id and
        declare their backend set through the reference fields they carry
        (ollama, llama, ...).
      '';
    };

    models = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Managed catalog keys for this host, in pull order. This is the only
        selection list; each backend serves exactly the selected models that
        carry its reference field, and a model carrying no backend reference
        is a configuration error.
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

    backends.ollama = {
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
      readyTarget = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
      };
      requiredModels = mkOption {
        type = types.listOf types.str;
        readOnly = true;
      };
    };

    backends.llamaRouter = {
      runtimes = mkOption {
        type = types.attrsOf llamaRuntimeType;
        default = {};
        description = ''
          Named llama.cpp engines, keyed by runtime. Catalog entries select an
          engine with llama.runtime (default `default`, the upstream build).
          Each engine owns its
          deployments, cache, and reconciler so fork builds never serve
          another engine's models.
        '';
      };
      active = mkOption {
        type = types.bool;
        readOnly = true;
      };
      runtimesInfo = mkOption {
        type = types.attrsOf types.attrs;
        readOnly = true;
        description = ''
          Evaluated per-runtime projections keyed by runtime name: urls, ports,
          portsByName, serviceNames, readyTarget, requiredModels, modelPresets,
          cacheDir, and active.
        '';
      };
    };
  };

  config = mkMerge [
    {
      services.ai = {
        backends.ollama = {
          active = ollamaDeployments != [];
          serviceNames = ollamaProjection.serviceNames;
          urls = ollamaProjection.urls;
          ports = ollamaProjection.ports;
          portsByName = ollamaProjection.portsByName;
          readyTarget = ollamaProjection.readyTarget;
          requiredModels = ollamaRequired;
        };
        backends.llamaRouter = {
          active = activeLlamaRuntimes != [];
          runtimesInfo = lib.genAttrs llamaRuntimeNames (runtime: let
            projection = runtimeProjection runtime;
          in {
            active = llamaActiveFor runtime;
            serviceNames = projection.serviceNames;
            urls = projection.urls;
            ports = projection.ports;
            portsByName = projection.portsByName;
            readyTarget = projection.readyTarget;
            requiredModels = runtimeRequired runtime;
            modelPresets = runtimeModelPresets runtime;
            cacheDir = resolvedCacheDir runtime;
          });
        };
      };
    }

    # Reconciler wiring. The default runtime keeps the historical
    # "<stack>-llama-router-models" unit names; extra runtimes nest under the
    # backend name so each engine reconciles its own cache independently. The
    # content keys stay static so the module system can resolve definition
    # paths before config is fixed; only values read the runtime list.
    (mkIf ollamaActive ollamaBinding)
    (mkIf
      (stackReady && selectionValid)
      {
        systemd.user.services = lib.mkMerge (builtins.map (binding: binding.systemd.user.services) activeRuntimeBindings);
        systemd.user.targets = lib.mkMerge (builtins.map (binding: binding.systemd.user.targets) activeRuntimeBindings);
        assertions = builtins.concatLists (builtins.map (binding: binding.assertions) activeRuntimeBindings);
      })
    (mkIf
      (stackReady && selectionValid)
      {
        services.podman-compose.${stackName}.instances = builtins.listToAttrs (builtins.concatMap (runtime:
          builtins.map (deployment: {
            name = depInstance "llamaRouter" deployment;
            value.files."models.ini".text = (llamaBinding runtime).modelsPresetIni;
          })
          (runtimeDeployments runtime))
        activeLlamaRuntimes);
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
    # guarantees they exist with stack ownership. The AI parent is explicit so
    # tmpfiles never creates a root-owned intermediate directory below the
    # stack-owned data root.
    {
      systemd.tmpfiles.rules = lib.unique (
        lib.optional
        (stackReady && aiStorageUser != null)
        "d /var/lib/${stackName}/ai 0755 ${aiStorageUser} ${aiStorageUser} -"
        ++ lib.optional
        (ollamaProjection.user != null && cfg.backends.ollama.modelsDir != null)
        "d ${cfg.backends.ollama.modelsDir} 0755 ${ollamaProjection.user} ${ollamaProjection.user} -"
        ++ builtins.concatMap (runtime: let
          projection = runtimeProjection runtime;
          cacheDir = resolvedCacheDir runtime;
        in
          lib.optional
          (projection.user != null && cacheDir != null)
          "d ${cacheDir} 0755 ${projection.user} ${projection.user} -")
        llamaRuntimeNames
      );
    }

    # Eval-time invariants.
    {
      assertions = let
        roleKeys = builtins.filter (role: cfg.roles.${role} != null) ["main" "smallTask" "embedding"];
        badRoles = builtins.filter (role: !builtins.elem cfg.roles.${role} cfg.models) roleKeys;
        anyBackends = ollamaDeployments != [] || builtins.any (runtime: runtimeDeployments runtime != []) llamaRuntimeNames;
        deploymentNames = builtins.map ({
          backend,
          deployment,
          ...
        }:
          depInstance backend deployment)
        allDeployments;
        deploymentPorts = builtins.map ({
          backend,
          deployment,
          ...
        }:
          deploymentPort backend deployment)
        allDeployments;
        deploymentServiceNames = builtins.map ({
          backend,
          deployment,
          ...
        }:
          deploymentServiceName backend deployment)
        allDeployments;
        instanceDefined = backend: deployment:
          stackReady
          && composeStack.instances ? ${depInstance backend deployment}
          && ((instanceConfig backend deployment).source or null) != null;
        backendUsersValid = projection: projection.user != null;
      in
        [
          {
            assertion = !anyBackends || stackReady;
            message = "services.ai: backends are enabled but services.ai.stack.name is not set (configure it in the stack's common host profile).";
          }
          {
            assertion = unknownKeys == [];
            message = "services.ai: unknown catalog keys: ${lib.concatStringsSep ", " unknownKeys}";
          }
          {
            assertion = invalidCatalogKeys == [];
            message = "services.ai.catalog: selected entries require a string id: ${lib.concatStringsSep ", " invalidCatalogKeys}";
          }
          {
            assertion = unserved == [];
            message = "services.ai: selected models declare no backend reference: ${lib.concatStringsSep ", " (builtins.map (entry: entry.id) unserved)}";
          }
          {
            assertion = unknownLlamaRuntime == [];
            message = "services.ai: selected models reference undeclared llama runtimes: ${lib.concatStringsSep ", " (builtins.map (entry: "${entry.id}=${aiLib.llamaRuntime entry}") unknownLlamaRuntime)}";
          }
          {
            assertion = badRoles == [];
            message = "services.ai.roles: keys outside the managed model selection: ${lib.concatStringsSep ", " (builtins.map (role: "${role}=${cfg.roles.${role}}") badRoles)}";
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
            assertion = ollamaDeployments == [] || backendUsersValid ollamaProjection;
            message = "services.ai.backends.ollama: deployments must resolve to one systemd user.";
          }
        ]
        ++ builtins.map (runtime: {
          assertion = runtimeDeployments runtime == [] || backendUsersValid (runtimeProjection runtime);
          message = "services.ai.backends.llamaRouter.runtimes.${runtime}: deployments must resolve to one systemd user.";
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
