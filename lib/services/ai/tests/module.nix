{pkgs}: let
  lib = pkgs.lib;
  inherit (lib) mkOption types;

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

  baseInstances = {
    ollama = {
      source = "ollama";
      serviceName = "special-ollama";
      exposedPorts.main.port = 11434;
    };
    ollama-2 = {
      source = "ollama-2";
      exposedPorts.main.port = 11435;
    };
    llama-router = {
      source = "llama-router";
      exposedPorts.main.port = 11436;
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
        llamaRouter.deployments = [
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

  badKeyCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.ollama.models = models ++ ["gemma99-typo"];
  };
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
    services.ai.backends.llamaRouter.deployments = [
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
      llamaRouter.deployments = [{}];
    };
  };
  backendSpecificCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = {
        only-ollama = {
          id = "only-ollama";
          ollama = "only-ollama:1";
        };
        only-llama = {
          id = "only-llama";
          llama = "example/only-llama-GGUF:Q4_K_M";
        };
      };
      models = [];
      roles = {
        main = "only-ollama";
        embedding = null;
      };
      backends = {
        ollama.models = ["only-ollama"];
        llamaRouter.models = ["only-llama"];
      };
    };
  };
in
  assert allAssertionsHold cfg;
  assert cfg.services.ai.backends.ollama.urls == ["http://127.0.0.1:11434" "http://127.0.0.1:11435"];
  assert cfg.services.ai.backends.ollama.ports == [11434 11435];
  assert cfg.services.ai.backends.ollama.portsByName
  == {
    ollama = 11434;
    ollama-2 = 11435;
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
  assert cfg.services.ai.backends.llamaRouter.portsByName."llama-router" == 11436;
  assert cfg.services.ai.backends.llamaRouter.requiredModels
  == [
    "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
    "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
    "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-2B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
  ];
  assert cfg.services.ai.backends.llamaRouter.modelPresets."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
  == {
    alias = "nomic-embed-text";
    embeddings = "true";
    poll = "0";
  };
  assert cfg.services.podman-compose.test.instances.ollama.state == "stopped";
  assert cfg.services.podman-compose.test.instances.ollama-2.autoStart == false;
  assert cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text != "";
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
  assert builtins.any (rule: lib.hasPrefix "d /var/lib/test/ollama-models " rule) cfg.systemd.tmpfiles.rules;
  assert !(builtins.any (rule: lib.hasPrefix "d /var/lib/test-user/ai/reconciler " rule) cfg.systemd.tmpfiles.rules);
  assert (eval autoCfg).services.ai.backends.ollama.readyTarget == "special-ollama-ready.target";
  assert (eval autoCfg).services.ai.backends.llamaRouter.readyTarget == "custom-llama-router-ready.target";
  assert allAssertionsHold (eval backendSpecificCfg);
  assert (eval backendSpecificCfg).services.ai.backends.ollama.requiredModels == ["only-ollama:1"];
  assert (eval backendSpecificCfg).services.ai.backends.llamaRouter.requiredModels
  == ["example/only-llama-GGUF:Q4_K_M"];
  assert !(allAssertionsHold (eval badKeyCfg));
  assert !(allAssertionsHold (eval badRoleCfg));
  assert !(allAssertionsHold (eval missingInstanceCfg));
  assert !(allAssertionsHold (eval crossBackendNameCollisionCfg));
  assert !(allAssertionsHold (eval crossBackendPortCollisionCfg));
  assert !(allAssertionsHold (eval missingStackCfg));
    pkgs.runCommand "ai-module-test" {} ''
      touch $out
    ''
