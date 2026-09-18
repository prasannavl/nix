{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ai;
  inherit (lib) mkIf mkMerge mkOption types;

  aiLib = import ./default.nix {inherit lib;};
  catalog = aiLib.catalog;

  stackName = cfg.stack.name;
  stackReady = stackName != null;

  # Canonical podman-compose instance name for a backend deployment when the
  # deployment does not pin one explicitly.
  defaultInstanceName = {
    ollama = "ollama";
    llamaRouter = "llama-router";
  };

  deploymentType = types.submodule {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Podman-compose instance name for this deployment. Defaults to the
          backend's canonical instance name.
        '';
      };
      port = mkOption {
        type = types.port;
        description = "Host port this deployment serves its API on.";
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

  # Selected catalog entries in the host's selection order. Unknown keys map
  # to a sentinel entry so assertions can report them; reconciler emissions
  # stay gated on catalog completeness below.
  selected = builtins.map (key:
    catalog.${
      key
    } or {
      id = key;
      missing = true;
    })
  cfg.models;
  unknownKeys = aiLib.missingKeys cfg.models;
  selectionValid = unknownKeys == [];

  # A backend only emits anything once the stack identity is known and the
  # selection is fully resolvable; otherwise the assertions below report the
  # misconfiguration instead of crashing the evaluation.
  ollamaActive =
    stackReady
    && ollamaDeployments != []
    && selectionValid
    && aiLib.missingRefs "ollama" selected == [];
  llamaActive =
    stackReady
    && llamaDeployments != []
    && selectionValid
    && aiLib.missingRefs "llama" selected == [];

  depName = backend: deployment:
    if deployment.name != null
    then deployment.name
    else defaultInstanceName.${backend};

  ollamaRequired = aiLib.projectModels "ollama" selected;
  llamaRequired = aiLib.projectModels "llama" selected;
  llamaModelPresets =
    aiLib.llamaPresets
    (
      if cfg.roles.embedding == null
      then null
      else (catalog.${cfg.roles.embedding} or {id = null;}).id
    )
    selected;

  backendProjections = backend: deployments: let
    names = builtins.map (depName backend) deployments;
    autos = builtins.filter (deployment: deployment.lifecycle == "auto") deployments;
  in {
    inherit names autos;
    serviceNames = builtins.map (name: "${stackName}-${name}.service") names;
    urls = builtins.map (deployment: "http://127.0.0.1:${toString deployment.port}") deployments;
    ports = builtins.map (deployment: deployment.port) deployments;
    portsByName = builtins.listToAttrs (builtins.map (deployment: {
        name = depName backend deployment;
        value = deployment.port;
      })
      deployments);
    readyTarget =
      if autos == []
      then null
      else "${stackName}-${depName backend (builtins.head autos)}-ready.target";
  };

  ollamaProjection = backendProjections "ollama" ollamaDeployments;
  llamaProjection = backendProjections "llamaRouter" llamaDeployments;

  # Reconcilers restart when any deployment's container configuration
  # changes (e.g. an image bump), re-checking pulled models.
  deploymentStamp = backend: deployments:
    builtins.hashString "sha256" (builtins.toJSON (builtins.listToAttrs (builtins.map (deployment: {
        name = depName backend deployment;
        value = config.services.podman-compose.${stackName}.instances.${depName backend deployment};
      })
      deployments)));

  ollamaReconciler = import ../ollama {inherit lib pkgs;};
  llamaReconciler = import ../llama-router {inherit lib pkgs;};

  ollamaBinding = ollamaReconciler.mkModelReconciler {
    backendServices = ollamaProjection.serviceNames;
    conditionUser = stackName;
    managedTarget = "${stackName}-managed";
    name = "${stackName}-ollama-models";
    ollamaUrls = ollamaProjection.urls;
    readyTarget = ollamaProjection.readyTarget;
    reconcileTriggers = [(deploymentStamp "ollama" ollamaDeployments)];
    requiredModels = ollamaRequired;
    retiredModels = cfg.backends.ollama.retiredModels;
    timeoutReadySeconds = 3600;
  };

  llamaBinding = llamaReconciler.mkModelReconciler {
    backendServices = llamaProjection.serviceNames;
    cacheDir = cfg.backends.llamaRouter.cacheDir;
    conditionUser = stackName;
    managedTarget = "${stackName}-managed";
    modelPresets = llamaModelPresets;
    name = "${stackName}-llama-router-models";
    readyTarget = llamaProjection.readyTarget;
    reconcileTriggers = [(deploymentStamp "llamaRouter" llamaDeployments)];
    requiredModels = llamaRequired;
    retiredModels = cfg.backends.llamaRouter.retiredModels;
    routerUrls = llamaProjection.urls;
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
in {
  options.services.ai = {
    stack.name = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Fleet stack identity backing the AI services ("pvl", "abird").
        Derives the reconciler user, unit prefix, managed target, and default
        cache locations. Set once by the stack's common host profile.
      '';
    };

    models = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Catalog keys this host serves, in pull order. This is the host's
        complete model policy: every enabled backend serves exactly this
        selection through its own references.
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
          it and reconcilers treat it as the pull source of truth.
        '';
      };
      retiredModels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Ollama tags this host historically served; reconcilers remove them when present.";
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
      retiredModels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "GGUF references this host historically served; reconcilers remove them when present.";
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
    (mkIf
      llamaActive
      (mkMerge [
        (builtins.removeAttrs llamaBinding ["modelsPresetIni"])
        {
          services.podman-compose.${stackName}.instances = builtins.listToAttrs (builtins.map (deployment: {
              name = depName "llamaRouter" deployment;
              value.files."models.ini".text = llamaBinding.modelsPresetIni;
            })
            llamaDeployments);
        }
      ]))

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
            name = depName backend deployment;
            value = {
              autoStart = mkIf (deployment.lifecycle == "manual") false;
              state = mkIf (deployment.lifecycle == "stopped") "stopped";
            };
          })
          allDeployments);
      })

    # Storage locations. Container files bind-mount these paths; tmpfiles
    # guarantees they exist with stack ownership.
    {
      systemd.tmpfiles.rules = mkMerge [
        (mkIf
          (stackReady && cfg.backends.ollama.modelsDir != null)
          ["d ${cfg.backends.ollama.modelsDir} 0755 ${stackName} ${stackName} -"])
        (mkIf
          (llamaActive && cfg.backends.llamaRouter.cacheDir != null)
          ["d ${cfg.backends.llamaRouter.cacheDir} 0755 ${stackName} ${stackName} -"])
      ];
    }

    # Eval-time invariants.
    {
      assertions = let
        ollamaMissing = aiLib.missingRefs "ollama" selected;
        llamaMissing = aiLib.missingRefs "llama" selected;
        roleKeys = builtins.filter (role: cfg.roles.${role} != null) ["main" "smallTask" "embedding"];
        badRoles = builtins.filter (role: !builtins.elem cfg.roles.${role} cfg.models) roleKeys;
        anyBackends = ollamaDeployments != [] || llamaDeployments != [];
        duplicateFree = backend: deployments: let
          names = builtins.map (depName backend) deployments;
          ports = builtins.map (deployment: deployment.port) deployments;
        in
          builtins.length (lib.unique names)
          == builtins.length names
          && builtins.length (lib.unique ports) == builtins.length ports;
        # The module's own lifecycle/files emissions create instance attrs, so
        # existence is probed via the host-owned compose source. Quadlet and
        # compose instances alike declare their compose content there.
        instanceDefined = backend: deployment: let
          name = depName backend deployment;
        in
          stackReady
          && config.services.podman-compose.${stackName}.instances ? ${name}
          && config.services.podman-compose.${stackName}.instances.${name}.source != null;
      in
        [
          {
            assertion = !anyBackends || stackReady;
            message = "services.ai: backends are enabled but services.ai.stack.name is not set (configure it in the stack's common host profile).";
          }
          {
            assertion = unknownKeys == [];
            message = "services.ai.models: unknown catalog keys: ${lib.concatStringsSep ", " unknownKeys}";
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
            message = "services.ai.roles: keys outside the services.ai.models selection: ${lib.concatStringsSep ", " (builtins.map (role: "${role}=${cfg.roles.${role}}") badRoles)}";
          }
          {
            assertion = ollamaDeployments == [] || duplicateFree "ollama" ollamaDeployments;
            message = "services.ai.backends.ollama: deployments have duplicate names or ports.";
          }
          {
            assertion = llamaDeployments == [] || duplicateFree "llamaRouter" llamaDeployments;
            message = "services.ai.backends.llamaRouter: deployments have duplicate names or ports.";
          }
        ]
        ++ builtins.map ({
          backend,
          deployment,
        }: {
          assertion = !stackReady || !anyBackends || instanceDefined backend deployment;
          message = "services.ai.backends.${backend}: deployment ${depName backend deployment} has no matching podman-compose instance (declare its compose source).";
        })
        allDeployments;
    }
  ];
}
