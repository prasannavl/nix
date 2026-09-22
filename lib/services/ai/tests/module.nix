{pkgs}: let
  lib = pkgs.lib;
  inherit (lib) mkOption types;
  aiLib = import ../default.nix {inherit lib;};

  exposedPortType = types.submodule {
    options.port = mkOption {type = types.port;};
  };
  instanceType = types.submodule {
    options = {
      state = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      autoStart = mkOption {
        type = types.nullOr types.bool;
        default = null;
      };
      source = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      files = mkOption {
        type = types.attrs;
        default = {};
      };
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      serviceName = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      exposedPorts = mkOption {
        type = types.attrsOf exposedPortType;
        default = {};
      };
      serviceOverrides = mkOption {
        type = types.attrs;
        default = {};
      };
    };
  };
  stackType = types.submodule ({name, ...}: {
    options = {
      user = mkOption {
        type = types.str;
        default = "root";
      };
      servicePrefix = mkOption {
        type = types.str;
        default = "${name}-";
      };
      instances = mkOption {
        type = types.attrsOf instanceType;
        default = {};
      };
    };
  });

  stubModule = {
    options = {
      services.podman-compose = mkOption {
        type = types.attrsOf stackType;
        default = {};
      };
      systemd = {
        user.services = mkOption {
          type = types.attrsOf types.anything;
          default = {};
        };
        user.targets = mkOption {
          type = types.attrsOf types.anything;
          default = {};
        };
        tmpfiles.rules = mkOption {
          type = types.listOf types.str;
          default = [];
        };
      };
      assertions = mkOption {
        type = types.listOf types.anything;
        default = [];
      };
    };
  };

  eval = moduleConfig:
    (lib.evalModules {
      modules = [
        (import ../module.nix)
        stubModule
        moduleConfig
      ];
      specialArgs = {inherit pkgs;};
    })
    .config;

  models = [
    "nomic-embed-text"
    "gemma4-e2b"
    "gemma4-e4b"
    "qwen35-08b"
    "qwen35-2b"
    "qwen35-4b"
    "qwen35-9b"
  ];
  llamaRefs = [
    "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
    "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
    "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-2B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
  ];
  bonsaiRef = "prism-ml/Ternary-Bonsai-2-27B-gguf:PTQ1_0";

  baseInstances = {
    ollama = {
      source = "ollama";
      serviceName = "special-ollama";
      exposedPorts.main.port = 11434;
    };
    ollama-2 = {
      source = "ollama-2";
      exposedPorts.main.port = 12434;
    };
    llama-router = {
      source = "llama-router";
      exposedPorts.main.port = 11000;
    };
    llama-router-prism = {
      source = "llama-router-prism";
      exposedPorts.main.port = 13000;
    };
  };

  baseConfig = {
    services.ai = {
      stack.name = "test";
      inherit models;
      roles.embedding = "nomic-embed-text";
      backends = {
        ollama = {
          modelsDir = "/var/lib/test/ollama-models";
          deployments = [
            {
              instance = "ollama";
              lifecycle = "stopped";
            }
            {
              instance = "ollama-2";
              lifecycle = "manual";
            }
          ];
        };
        llamaRouter.runtimes.default.deployments = [
          {
            lifecycle = "manual";
          }
        ];
      };
    };
    services.podman-compose.test = {
      user = "test-user";
      servicePrefix = "custom-";
      instances = baseInstances;
    };
  };

  cfg = eval baseConfig;
  allAssertionsHold = value: builtins.all (assertion: assertion.assertion) value.assertions;

  badRoleCfg = lib.recursiveUpdate baseConfig {
    services.ai.roles.main = "gemma4-26b";
  };
  missingInstanceCfg =
    baseConfig
    // {
      services =
        baseConfig.services
        // {
          podman-compose.test =
            baseConfig.services.podman-compose.test
            // {
              instances = builtins.removeAttrs baseInstances ["llama-router"];
            };
        };
    };
  crossBackendNameCollisionCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.runtimes.default.deployments = [
      {
        instance = "ollama";
        lifecycle = "manual";
      }
    ];
  };
  crossBackendPortCollisionCfg = lib.recursiveUpdate baseConfig {
    services.podman-compose.test.instances.llama-router.exposedPorts.main.port = 11434;
  };
  missingStackCfg = {
    services.ai = {
      inherit models;
      backends.ollama.deployments = [{}];
    };
  };
  autoCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends = {
      ollama.deployments = [{instance = "ollama";}];
      llamaRouter.runtimes.default.deployments = [{}];
    };
  };
  customLlamaCacheCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.runtimes.default.cacheDir = "/mnt/models/llama-router";
  };
  idleTimeoutCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.runtimes.default.idleTimeoutSeconds = 300;
  };
  # A model with no backend reference is a selection error: membership is
  # derived from the catalog schema, so there is nowhere for it to run.
  unservedCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = {
        hf-only = {
          id = "hf-only";
          hf = "example/hf-only";
        };
      };
      models = ["hf-only"];
    };
  };
  # A llama reference naming a runtime this host does not deploy is a typo
  # worth failing on rather than silently dropping.
  unknownRuntimeCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = {
        ghost = {
          id = "ghost";
          llama = {
            ref = "example/ghost-GGUF:Q4_K_M";
            runtime = "ghost";
          };
        };
      };
      models = ["ghost"];
    };
  };
  # The fork engine runs side by side with upstream and serves only the
  # models pinned to its runtime.
  prismCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = lib.recursiveUpdate aiLib.catalog {
        bonsai = {
          id = "bonsai2:27b";
          llama = {
            ref = bonsaiRef;
            runtime = "prism";
            preset.jinja = "true";
          };
        };
      };
      models = models ++ ["bonsai"];
      backends.llamaRouter.runtimes.prism.deployments = [
        {
          instance = "llama-router-prism";
          lifecycle = "stopped";
        }
      ];
    };
  };
  prism = eval prismCfg;
in
  assert allAssertionsHold cfg;
  assert cfg.services.ai.backends.ollama.urls == ["http://127.0.0.1:11434" "http://127.0.0.1:12434"];
  assert cfg.services.ai.backends.ollama.ports == [11434 12434];
  assert cfg.services.ai.backends.ollama.portsByName
  == {
    ollama = 11434;
    ollama-2 = 12434;
  };
  assert cfg.services.ai.backends.ollama.serviceNames == ["special-ollama.service" "custom-ollama-2.service"];
  assert cfg.services.ai.backends.ollama.readyTarget == null;
  assert cfg.services.ai.backends.ollama.requiredModels
  == [
    "nomic-embed-text"
    "gemma4:e2b"
    "gemma4:e4b"
    "qwen3.5:0.8b"
    "qwen3.5:2b"
    "qwen3.5:4b"
    "qwen3.5:9b"
  ];
  assert cfg.services.ai.backends.llamaRouter.active;
  assert cfg.services.ai.backends.llamaRouter.runtimesInfo.default.portsByName."llama-router" == 11000;
  assert cfg.services.ai.backends.llamaRouter.runtimesInfo.default.requiredModels == llamaRefs;
  assert cfg.services.ai.backends.llamaRouter.runtimesInfo.default.modelPresets."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
  == {
    alias = "nomic-embed-text";
    embeddings = "true";
    poll = "0";
  };
  assert cfg.services.podman-compose.test.instances.ollama.state == "stopped";
  assert cfg.services.podman-compose.test.instances.ollama-2.autoStart == false;
  assert cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text != "";
  # Idle sleep is opt-in: the default emits no [*] section, so models stay
  # resident until LRU eviction (pre-existing behavior).
  assert !(lib.hasInfix "sleep-idle-seconds" cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text);
  assert lib.hasInfix "[*]\nsleep-idle-seconds = 300\n" (eval idleTimeoutCfg).services.podman-compose.test.instances.llama-router.files."models.ini".text;
  assert builtins.any
  (lib.hasInfix "restart --no-block test-ollama-models-pull.service")
  cfg.systemd.user.services.special-ollama.serviceConfig.ExecStartPost;
  assert builtins.any
  (lib.hasInfix "restart --no-block test-llama-router-models-load.service")
  cfg.systemd.user.services.custom-llama-router.serviceConfig.ExecStartPost;
  assert cfg.systemd.user.services ? "test-ollama-models";
  assert cfg.systemd.user.services ? "test-ollama-models-pull";
  assert cfg.systemd.user.services ? "test-llama-router-models";
  assert cfg.systemd.user.services ? "test-llama-router-models-load";
  assert cfg.systemd.user.services."test-ollama-models".serviceConfig.StateDirectory == "ai/reconciler";
  assert cfg.systemd.user.services."test-ollama-models".environment.MODEL_RECONCILER_STATE_NAME == "ollama.json";
  assert cfg.systemd.user.services."test-ollama-models".environment.MODEL_RECONCILER_LEGACY_STATE_FILE
  == "/var/lib/test-user/ai/reconciler/ollama.json";
  assert cfg.systemd.user.services."test-llama-router-models".serviceConfig.StateDirectory == "ai/reconciler";
  assert cfg.systemd.user.services."test-llama-router-models".environment.MODEL_RECONCILER_STATE_NAME
  == "llama-router.json";
  assert cfg.systemd.user.services."test-llama-router-models".environment.MODEL_RECONCILER_LEGACY_STATE_FILE
  == "/var/lib/test-user/ai/reconciler/llama-router.json";
  assert cfg.systemd.tmpfiles.rules
  == [
    "d /var/lib/test/ai 0755 test-user test-user -"
    "d /var/lib/test/ollama-models 0755 test-user test-user -"
    "d /var/lib/test/ai/llama-router 0755 test-user test-user -"
  ];
  assert !(builtins.any (rule: lib.hasPrefix "d /var/lib/test-user/ai/reconciler " rule) cfg.systemd.tmpfiles.rules);
  assert (eval customLlamaCacheCfg).services.ai.backends.llamaRouter.runtimesInfo.default.cacheDir == "/mnt/models/llama-router";
  assert builtins.elem
  "d /mnt/models/llama-router 0755 test-user test-user -"
  (eval customLlamaCacheCfg).systemd.tmpfiles.rules;
  assert !(builtins.any
    (rule: lib.hasPrefix "d /mnt " rule || lib.hasPrefix "d /mnt/models " rule)
    (eval customLlamaCacheCfg).systemd.tmpfiles.rules);
  assert (eval autoCfg).services.ai.backends.ollama.readyTarget == "special-ollama-ready.target";
  assert (eval autoCfg).services.ai.backends.llamaRouter.runtimesInfo.default.readyTarget == "custom-llama-router-ready.target";
  # Fork runtime: separate cache, separate models.ini, separate reconciler.
  assert allAssertionsHold prism;
  assert prism.services.ai.backends.llamaRouter.runtimesInfo.prism.requiredModels == [bonsaiRef];
  assert prism.services.ai.backends.llamaRouter.runtimesInfo.prism.cacheDir == "/var/lib/test/ai/llama-router-prism";
  assert !(builtins.elem bonsaiRef prism.services.ai.backends.llamaRouter.runtimesInfo.default.requiredModels);
  assert !(builtins.elem "bonsai2:27b" prism.services.ai.backends.ollama.requiredModels);
  assert lib.hasInfix "[bonsai2:27b]" prism.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text;
  assert lib.hasInfix "hf = ${bonsaiRef}" prism.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text;
  assert !(lib.hasInfix "gemma" prism.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text);
  assert !(lib.hasInfix "bonsai" prism.services.podman-compose.test.instances.llama-router.files."models.ini".text);
  assert prism.systemd.user.services ? "test-llama-router-prism-models";
  assert prism.systemd.user.services ? "test-llama-router-prism-models-load";
  assert prism.systemd.user.services."test-llama-router-prism-models".environment.MODEL_RECONCILER_STATE_NAME
  == "llama-router-prism.json";
  assert !(prism.systemd.user.services."test-llama-router-prism-models".environment ? MODEL_RECONCILER_LEGACY_STATE_FILE);
  assert builtins.elem
  "d /var/lib/test/ai/llama-router-prism 0755 test-user test-user -"
  prism.systemd.tmpfiles.rules;
  assert builtins.any
  (lib.hasInfix "restart --no-block test-llama-router-prism-models-load.service")
  prism.systemd.user.services.custom-llama-router-prism.serviceConfig.ExecStartPost;
  assert !(allAssertionsHold (eval badRoleCfg));
  assert !(allAssertionsHold (eval missingInstanceCfg));
  assert !(allAssertionsHold (eval crossBackendNameCollisionCfg));
  assert !(allAssertionsHold (eval crossBackendPortCollisionCfg));
  assert !(allAssertionsHold (eval missingStackCfg));
  assert !(allAssertionsHold (eval unservedCfg));
  assert !(allAssertionsHold (eval unknownRuntimeCfg));
    pkgs.runCommand "ai-module-test" {} ''
      touch $out
    ''
