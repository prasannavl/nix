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

  ollamaDeployments = cfg.backends.ollama.deployments;
  llamaDeployments = cfg.backends.llamaRouter.deployments;
  ollamaModelKeys =
    if cfg.backends.ollama.models == null
    then cfg.models
    else cfg.backends.ollama.models;
  llamaModelKeys =
    if cfg.backends.llamaRouter.models == null
    then cfg.models
    else cfg.backends.llamaRouter.models;
  selectedKeys = lib.unique (cfg.models ++ ollamaModelKeys ++ llamaModelKeys);

  selectedFor = keys:
    builtins.map (key: let
      entry = catalog.${key} or null;
    in
      if builtins.isAttrs entry && (entry ? id) && builtins.isString entry.id
      then entry
      else {
        id = key;
        missing = true;
      })
    keys;
  ollamaSelected = selectedFor ollamaModelKeys;
  llamaSelected = selectedFor llamaModelKeys;
  unknownKeys = aiLib.missingKeysFrom catalog selectedKeys;
  invalidCatalogKeys = builtins.filter (key: let
    entry = catalog.${key} or null;
  in
    entry != null && (!(builtins.isAttrs entry) || !(entry ? id) || !(builtins.isString entry.id)))
  selectedKeys;
  selectionValid = unknownKeys == [] && invalidCatalogKeys == [];
  ollamaPolicyValid = selectionValid && aiLib.missingRefs "ollama" ollamaSelected == [];
  llamaPolicyValid = selectionValid && aiLib.missingRefs "llama" llamaSelected == [];

  # A backend only emits anything once the stack identity is known and the
  # selection is fully resolvable; otherwise the assertions below report the
  # misconfiguration instead of crashing the evaluation.
  ollamaActive =
    stackReady
    && ollamaDeployments != []
    && ollamaPolicyValid
    && ollamaProjection.user != null;
  llamaActive =
    stackReady
    && llamaDeployments != []
    && llamaPolicyValid
    && llamaProjection.user != null;

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

  ollamaRequired =
    if ollamaPolicyValid
    then aiLib.projectModels "ollama" ollamaSelected
    else [];
  llamaRequired =
    if llamaPolicyValid
    then aiLib.projectModels "llama" llamaSelected
    else [];
  llamaModelPresets =
    if llamaPolicyValid
    then
      aiLib.llamaPresets
      (
        if cfg.roles.embedding == null
        then null
        else (catalog.${cfg.roles.embedding} or {id = null;}).id
      )
      llamaSelected
    else {};

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
  llamaProjection = backendProjections "llamaRouter" llamaDeployments;

  legacyStateFile = backend: projection:
    if projection.user == null
    then null
    else "/var/lib/${projection.user}/ai/reconciler/${backend}.json";

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

  llamaBinding = llamaReconciler.mkModelReconciler {
    backendServices = llamaProjection.serviceNames;
    conditionUser = llamaProjection.user;
    managedTarget = "${lib.strings.sanitizeDerivationName llamaProjection.user}-managed";
    modelPresets = llamaModelPresets;
    name = "${stackName}-llama-router-models";
    preservedModels = cfg.backends.llamaRouter.preservedModels;
    readyTarget = llamaProjection.readyTarget;
    requiredModels = llamaRequired;
    routerUrls = llamaProjection.urls;
    legacyStateFile = legacyStateFile "llama-router" llamaProjection;
    timeoutReadySeconds = 3600;
  };

  allDeployments =
    builtins.map (deployment: {
      backend = "ollama";
      inherit deployment;
    })
    ollamaDeployments
    ++ builtins.map (deployment: {
      backend = "llamaRouter";
      inherit deployment;
    })
    llamaDeployments;
  backendWorkerName = backend:
    if backend == "ollama"
    then "${stackName}-ollama-models-pull"
    else "${stackName}-llama-router-models-load";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  backendReconcileCommand = backend: "-${systemctl} --user restart --no-block ${backendWorkerName backend}.service";
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
        only the references used by their selected backends.
      '';
    };

    models = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Default managed catalog keys for this host, in pull order. A backend
        may override this selection when it intentionally serves a different
        model set.
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
      models = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Managed catalog keys for Ollama; null inherits services.ai.models.";
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
      models = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Managed catalog keys for llama.cpp router; null inherits services.ai.models.";
      };
      deployments = mkOption {
        type = types.listOf deploymentType;
        default = [];
        description = "llama.cpp router container deployments serving this host's model selection.";
      };
      cacheDir = mkOption {
        type = types.nullOr types.str;
        default =
          if stackReady
          then "/var/lib/${stackName}/ai/llama-router"
          else null;
        description = "Download cache for GGUF model files.";
      };
      preservedModels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Exact managed GGUF references to retain while relinquishing
          ownership. Ad-hoc cache entries are unowned and always untouched.
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
      modelPresets = mkOption {
        type = types.attrsOf (types.attrsOf types.str);
        readOnly = true;
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
          active = llamaDeployments != [];
          serviceNames = llamaProjection.serviceNames;
          urls = llamaProjection.urls;
          ports = llamaProjection.ports;
          portsByName = llamaProjection.portsByName;
          readyTarget = llamaProjection.readyTarget;
          requiredModels = llamaRequired;
          modelPresets = llamaModelPresets;
        };
      };
    }

    # Reconciler wiring. Unit names follow "<stack>-<backend>-models" and are
    # unchanged from the pre-module host modules by construction.
    (mkIf ollamaActive ollamaBinding)
    (mkIf llamaActive (builtins.removeAttrs llamaBinding ["modelsPresetIni"]))
    (mkIf
      (stackReady && llamaDeployments != [] && llamaPolicyValid)
      {
        services.podman-compose.${stackName}.instances = builtins.listToAttrs (builtins.map (deployment: {
            name = depInstance "llamaRouter" deployment;
            value.files."models.ini".text = llamaBinding.modelsPresetIni;
          })
          llamaDeployments);
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
            deployment,
          }: {
            name = deploymentServiceName backend deployment;
            value.serviceConfig.ExecStartPost = lib.mkAfter [(backendReconcileCommand backend)];
          })
          allDeployments);
      })

    # Storage locations. Container files bind-mount these paths; tmpfiles
    # guarantees they exist with stack ownership.
    {
      systemd.tmpfiles.rules = lib.unique (
        lib.optional
        (ollamaProjection.user != null && cfg.backends.ollama.modelsDir != null)
        "d ${cfg.backends.ollama.modelsDir} 0755 ${ollamaProjection.user} ${ollamaProjection.user} -"
        ++ lib.optional
        (llamaProjection.user != null && cfg.backends.llamaRouter.cacheDir != null)
        "d ${cfg.backends.llamaRouter.cacheDir} 0755 ${llamaProjection.user} ${llamaProjection.user} -"
      );
    }

    # Eval-time invariants.
    {
      assertions = let
        ollamaMissing = aiLib.missingRefs "ollama" ollamaSelected;
        llamaMissing = aiLib.missingRefs "llama" llamaSelected;
        roleKeys = builtins.filter (role: cfg.roles.${role} != null) ["main" "smallTask" "embedding"];
        badRoles = builtins.filter (role: !builtins.elem cfg.roles.${role} selectedKeys) roleKeys;
        anyBackends = ollamaDeployments != [] || llamaDeployments != [];
        deploymentNames = builtins.map ({
          backend,
          deployment,
        }:
          depInstance backend deployment)
        allDeployments;
        deploymentPorts = builtins.map ({
          backend,
          deployment,
        }:
          deploymentPort backend deployment)
        allDeployments;
        deploymentServiceNames = builtins.map ({
          backend,
          deployment,
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
            assertion = ollamaDeployments == [] || ollamaMissing == [];
            message = "services.ai.backends.ollama: selected models without an ollama reference: ${lib.concatStringsSep ", " (builtins.map (entry: entry.id) ollamaMissing)}";
          }
          {
            assertion = llamaDeployments == [] || llamaMissing == [];
            message = "services.ai.backends.llamaRouter: selected models without a llama reference: ${lib.concatStringsSep ", " (builtins.map (entry: entry.id) llamaMissing)}";
          }
          {
            assertion = badRoles == [];
            message = "services.ai.roles: keys outside all managed model selections: ${lib.concatStringsSep ", " (builtins.map (role: "${role}=${cfg.roles.${role}}") badRoles)}";
          }
          {
            assertion = builtins.length (lib.unique deploymentNames) == builtins.length deploymentNames;
            message = "services.ai: deployment instance names must be unique across backends.";
          }
          {
            assertion = builtins.length (lib.unique deploymentServiceNames) == builtins.length deploymentServiceNames;
            message = "services.ai: resolved deployment service names must be unique across backends.";
          }
          {
            assertion = builtins.length (lib.unique deploymentPorts) == builtins.length deploymentPorts;
            message = "services.ai: deployment API ports must be unique across backends.";
          }
          {
            assertion = ollamaDeployments == [] || backendUsersValid ollamaProjection;
            message = "services.ai.backends.ollama: deployments must resolve to one systemd user.";
          }
          {
            assertion = llamaDeployments == [] || backendUsersValid llamaProjection;
            message = "services.ai.backends.llamaRouter: deployments must resolve to one systemd user.";
          }
        ]
        ++ builtins.map ({
          backend,
          deployment,
        }: {
          assertion = !stackReady || !anyBackends || instanceDefined backend deployment;
          message = "services.ai.backends.${backend}: deployment ${depInstance backend deployment} has no matching podman-compose instance.";
        })
        allDeployments
        ++ builtins.map ({
          backend,
          deployment,
        }: {
          assertion = !instanceDefined backend deployment || deploymentPortResolved backend deployment;
          message = "services.ai.backends.${backend}: deployment ${depInstance backend deployment} must select an existing exposed API port (set portName when the instance exposes more than one).";
        })
        allDeployments;
    }
  ];
}
