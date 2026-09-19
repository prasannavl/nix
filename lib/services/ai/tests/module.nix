{pkgs}: let
  lib = pkgs.lib;
  inherit (lib) mkOption types;

  # Minimal option stubs for the surfaces the ai module assigns to; keeps the
  # test independent of the full compose module while exercising the module's
  # own projections and emissions.
  stubModule = {
    options = {
      services.podman-compose = mkOption {
        type = types.attrsOf (types.attrsOf (types.attrsOf (types.submodule {
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
            # Raw attrs: instance file payloads stay unforced until read, so
            # existence checks do not evaluate reconciler-derived texts.
            files = mkOption {
              type = types.attrs;
              default = {};
            };
          };
        })));
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

  eval = cfg:
    (lib.evalModules {
      modules = [
        (import ../module.nix)
        stubModule
        cfg
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
              name = "ollama";
              port = 11434;
              lifecycle = "stopped";
            }
            {
              name = "ollama-2";
              port = 11435;
              lifecycle = "manual";
            }
          ];
        };
        llamaRouter.deployments = [
          {
            port = 11436;
            lifecycle = "manual";
          }
        ];
      };
    };
    services.podman-compose.test.instances = baseInstances;
  };

  cfg = eval baseConfig;

  allAssertionsHold = c: builtins.all (a: a.assertion) c.assertions;

  baseInstances = {
    ollama.source = "ollama";
    ollama-2.source = "ollama-2";
    llama-router.source = "llama-router";
  };

  # Failure variants; each keeps the happy-path shape but breaks one
  # invariant, and must fail at least one assertion.
  badKeyCfg = lib.recursiveUpdate baseConfig {
    services.ai.models = models ++ ["gemma99-typo"];
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
          podman-compose.test.instances = builtins.removeAttrs baseInstances ["llama-router"];
        };
    };
  duplicatePortCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.ollama.deployments = [
      {
        name = "ollama";
        port = 11434;
      }
      {
        name = "ollama-2";
        port = 11434;
      }
    ];
  };
  missingStackCfg =
    (builtins.removeAttrs baseConfig ["services.ai"])
    // {
      services.ai = {
        inherit models;
        backends.ollama.deployments = [{port = 11434;}];
      };
    };
  autoCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends = {
      ollama.deployments = [{port = 11434;}];
      llamaRouter.deployments = [{port = 11436;}];
    };
  };
in
  assert allAssertionsHold cfg;
  # Projections.
  assert cfg.services.ai.backends.ollama.urls == ["http://127.0.0.1:11434" "http://127.0.0.1:11435"];
  assert cfg.services.ai.backends.ollama.ports == [11434 11435];
  assert cfg.services.ai.backends.ollama.portsByName
  == {
    ollama = 11434;
    ollama-2 = 11435;
  };
  assert cfg.services.ai.backends.ollama.serviceNames == ["test-ollama.service" "test-ollama-2.service"];
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
  assert cfg.services.ai.backends.llamaRouter.cacheDir == "/var/lib/test/ai/llama-router";
  # Lifecycle projection onto compose instances.
  assert cfg.services.podman-compose.test.instances.ollama.state == "stopped";
  assert cfg.services.podman-compose.test.instances.ollama-2.autoStart == false;
  assert cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text != "";
  # Reconciler units under their canonical fleet names.
  assert cfg.systemd.user.services ? "test-ollama-models";
  assert cfg.systemd.user.services ? "test-ollama-models-pull";
  assert cfg.systemd.user.services ? "test-llama-router-models";
  assert cfg.systemd.user.services ? "test-llama-router-models-load";
  # Storage rules.
  assert builtins.any (rule: lib.hasPrefix "d /var/lib/test/ollama-models " rule) cfg.systemd.tmpfiles.rules;
  assert builtins.any (rule: lib.hasPrefix "d /var/lib/test/ai/llama-router " rule) cfg.systemd.tmpfiles.rules;
  # A single auto deployment yields its ready target.
  assert (eval autoCfg).services.ai.backends.ollama.readyTarget == "test-ollama-ready.target";
  # Auto llama deployments get ready-target ordering like the Ollama family.
  assert (eval autoCfg).services.ai.backends.llamaRouter.readyTarget == "test-llama-router-ready.target";
  # Manual/stopped backends keep readyTarget null.
  assert cfg.services.ai.backends.llamaRouter.readyTarget == null;
  # Failure variants must break assertions, not evaluation.
  assert !(allAssertionsHold (eval badKeyCfg));
  assert !(allAssertionsHold (eval badRoleCfg));
  assert !(allAssertionsHold (eval missingInstanceCfg));
  assert !(allAssertionsHold (eval duplicatePortCfg));
  assert !(allAssertionsHold (eval missingStackCfg));
    pkgs.runCommand "ai-module-test" {} ''
      touch $out
    ''
