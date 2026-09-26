{pkgs}: let
  lib = pkgs.lib;
  inherit (lib) mkOption types;
  catalog = import ../catalog.nix;
  projectionLib = import ../projection.nix;
  # Plan inspection is an evaluation-time test. Use a source store path here
  # so a cold store never turns the assertions below into import-from-
  # derivation; production still uses pkgs.writeText.
  modulePkgs = pkgs // {writeText = name: text: builtins.toFile name text;};

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
  userType = types.submodule {
    options = {
      uid = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      group = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
  };
  groupType = types.submodule {
    options.gid = mkOption {
      type = types.nullOr types.int;
      default = null;
    };
  };

  stubModule = {
    options = {
      services.podman-compose = mkOption {
        type = types.attrsOf stackType;
        default = {};
      };
      users = {
        users = mkOption {
          type = types.attrsOf userType;
          default = {};
        };
        groups = mkOption {
          type = types.attrsOf groupType;
          default = {};
        };
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
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [];
      };
      system = {
        systemBuilderCommands = mkOption {
          type = types.lines;
          default = "";
        };
        build = mkOption {
          type = types.attrsOf types.anything;
          default = {};
        };
      };
      assertions = mkOption {
        type = types.listOf types.anything;
        default = [];
      };
    };
  };

  evalModules = moduleConfigs:
    (lib.evalModules {
      modules =
        [
          (import ../module.nix)
          stubModule
        ]
        ++ moduleConfigs;
      specialArgs.pkgs = modulePkgs;
    })
    .config;
  eval = moduleConfig: evalModules [moduleConfig];

  models = [
    "nomic-embed-text-v15-100m"
    "gemma4-e2b"
    "gemma4-e4b"
    "qwen35-800m"
    "qwen35-2b"
    "qwen35-4b"
    "qwen35-9b"
  ];
  modelIds = [
    "nomic-embed-text"
    "gemma4:e2b"
    "gemma4:e4b"
    "qwen3.5:0.8b"
    "qwen3.5:2b"
    "qwen3.5:4b"
    "qwen3.5:9b"
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
      roles.embedding = "nomic-embed-text-v15-100m";
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
    users = {
      users.test-user = {
        uid = 1234;
        group = "test-user";
      };
      groups.test-user.gid = 1234;
    };
  };

  cfg = eval baseConfig;
  prefetchPlan = builtins.fromJSON (builtins.readFile cfg.system.build.aiModelPrefetchPlan);
  hfPrefetchCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      prefetch.qwen38-27b = true;
    };
  };
  hfPrefetch = eval hfPrefetchCfg;
  hfPrefetchRunner = builtins.head hfPrefetch.environment.systemPackages;
  hfPrefetchPlan = builtins.fromJSON (builtins.readFile hfPrefetch.system.build.aiModelPrefetchPlan);
  explicitHfArtifactsCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "test-user";
      prefetchDefaults.artifacts = false;
      prefetch = {
        gemma4-12b = ["bf16-eagle3"];
        qwen38-27b = true;
        qwen38-27b-fp8 = [];
      };
    };
  };
  explicitHfArtifacts = eval explicitHfArtifactsCfg;
  explicitHfArtifactsPlan = builtins.fromJSON (builtins.readFile explicitHfArtifacts.system.build.aiModelPrefetchPlan);
  artifactOnlyHfCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "test-user";
      prefetch.qwen38-27b = {
        base = false;
        artifacts = ["f16-mmproj" "q4-mtp"];
      };
    };
  };
  artifactOnlyHf = eval artifactOnlyHfCfg;
  artifactOnlyHfPlan = builtins.fromJSON (builtins.readFile artifactOnlyHf.system.build.aiModelPrefetchPlan);
  composedArtifactOnlyHf = evalModules [
    baseConfig
    {
      services.ai.backends.hf = {
        cacheDir = "/var/lib/test/huggingface";
        user = "test-user";
        prefetch.qwen38-27b.base = false;
      };
    }
    {
      services.ai.backends.hf.prefetch.qwen38-27b.artifacts = ["q4-mtp"];
    }
  ];
  composedArtifactOnlyHfPlan = builtins.fromJSON (builtins.readFile composedArtifactOnlyHf.system.build.aiModelPrefetchPlan);
  invalidHfPrefetchCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      prefetch.missing = true;
    };
  };
  invalidHfArtifactCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      prefetch.gemma4-12b = ["missing"];
    };
  };
  missingHfCacheCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.prefetch.qwen38-27b = true;
  };
  invalidHfCachePathCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.cacheDir = "relative/huggingface";
  };
  unsafeHfCachePathCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.cacheDir = "/var/lib/test/../huggingface";
  };
  unsafeHfWhitespacePathCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.cacheDir = "/var/lib/test/hugging face";
  };
  unsafeHfSpecifierPathCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.cacheDir = "/var/lib/test/huggingface-%n";
  };
  unsafeHfTokenPathCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf.tokenFile = "/run/secrets//huggingface-token";
  };
  missingHfOwnerCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "missing-hf-owner";
    };
    users.groups.missing-hf-owner.gid = 2347;
  };
  missingHfOwnerGroupCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "missing-hf-group-user";
    };
    users.users.missing-hf-group-user = {
      uid = 2348;
      group = "missing-hf-group";
    };
  };
  unfixedHfUidCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "unfixed-user";
      prefetch.qwen38-27b = true;
    };
    users = {
      users.unfixed-user.group = "unfixed-user";
      groups.unfixed-user.gid = 2345;
    };
  };
  unfixedHfGidCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.hf = {
      cacheDir = "/var/lib/test/huggingface";
      user = "unfixed-group-user";
      prefetch.qwen38-27b = true;
    };
    users.users.unfixed-group-user = {
      uid = 2346;
      group = "unfixed-group";
    };
    users.groups.unfixed-group = {};
  };
  outOfRangeHfUidCfg = lib.recursiveUpdate hfPrefetchCfg {
    users.users.test-user.uid = 2147483648;
  };
  outOfRangeHfGidCfg = lib.recursiveUpdate hfPrefetchCfg {
    users.groups.test-user.gid = 2147483648;
  };
  emptyPrefetch = eval {
    services.ai = {
      stack.name = "test";
      models = [];
      backends.hf.cacheDir = "/var/lib/test/empty-huggingface";
    };
    services.podman-compose.test.user = "test-user";
    users = baseConfig.users;
  };
  emptyPrefetchPlan = builtins.fromJSON (builtins.readFile emptyPrefetch.system.build.aiModelPrefetchPlan);
  stackOnly = eval {
    services.ai.stack.name = "test";
    services.podman-compose.test.user = "test-user";
    users = baseConfig.users;
  };
  nestedHfCache = eval {
    services.ai = {
      stack.name = "test";
      models = [];
      backends.hf.cacheDir = "/var/lib/test/ai/huggingface";
    };
    services.podman-compose.test.user = "test-user";
    users = baseConfig.users;
  };
  rootHfCache = eval {
    services.ai = {
      stack.name = "test";
      models = [];
      backends.hf.cacheDir = "/var/lib/test/ai";
    };
    services.podman-compose.test.user = "test-user";
    users = baseConfig.users;
  };
  allAssertionsHold = value: builtins.all (assertion: assertion.assertion) value.assertions;
  failureMessages = value:
    builtins.map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) value.assertions);

  badRoleCfg = lib.recursiveUpdate baseConfig {
    services.ai.roles.main = "gemma4-26b-a4b";
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
  missingInstancesCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.deployments = [
      {instance = "missing-a";}
      {instance = "missing-b";}
    ];
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
  customLlamaCacheCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.defaults.cacheDir = "/mnt/models/llama-router";
  };
  idleTimeoutCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.defaults.idleTimeoutSeconds = 300;
  };
  # models = null selects every model servable by the declared backends.
  autoModelsCfg = lib.recursiveUpdate baseConfig {
    services.ai.models = null;
  };
  autoServable =
    (projectionLib.resolvePolicy {
      inherit catalog;
      backends = autoModelsCfg.services.ai.backends;
    }).models;
  customProjection = projectionLib.mkProjection {
    catalog.custom = {
      id = "custom-model";
      ollama = "custom/model:1";
    };
    models = ["custom"];
    roles.main = "custom";
    backends = {
      hf.prefetchDefaults.artifacts = false;
      ollama = {
        active = true;
        deployments = [{}];
        ports = [1];
        requiredModels = ["derived-must-not-round-trip"];
      };
    };
  };
  customProjectionCfg = {
    services.ai = customProjection.moduleConfig // {stack.name = "test";};
    services.podman-compose.test = {
      user = "test-user";
      instances.ollama = baseInstances.ollama;
    };
  };
  customProjectionEval = eval customProjectionCfg;
  # Explicit admission may target a host-owned HF runtime such as vLLM/SGLang.
  hfOnlyCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = {
        hf-only = {
          id = "hf-only";
          hf = "example/hf-only";
        };
      };
      models = ["hf-only"];
      roles.embedding = null;
    };
  };
  # A model with no usable source remains an admission error.
  unservedCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog.unserved.id = "unserved";
      models = ["unserved"];
    };
  };
  # A model with no configured backend deployment is rejected even when its
  # catalog entry carries a syntactically valid backend reference.
  unknownRuntimeCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog = {
        ghost = {
          id = "ghost";
          llama = {
            ref = "example/ghost-GGUF:Q4_K_M";
            runtimes = ["ghost"];
          };
        };
      };
      models = ["ghost"];
    };
  };
  llamaOnlyAutoCfg = {
    services.ai = {
      stack.name = "test";
      catalog = {
        ollama-only = {
          id = "ollama-only";
          ollama = "ollama-only";
        };
        hf-only = {
          id = "hf-only";
          hf = "example/hf-only";
        };
        llama-only = {
          id = "llama-only";
          llama = "example/llama-only:Q4";
        };
      };
      models = null;
      backends.llamaRouter.deployments = [{}];
    };
    services.podman-compose.test = {
      user = "test-user";
      instances.llama-router = baseInstances.llama-router;
    };
  };
  # The fork engine runs side by side with upstream and serves only the
  # models pinned to its runtime.
  prismCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      models = models ++ ["bonsai2-27b"];
      backends.llamaRouter.deployments = [
        {
          lifecycle = "manual";
        }
        {
          instance = "llama-router-prism";
          lifecycle = "stopped";
          runtime = "prism";
        }
      ];
    };
  };
  prism = eval prismCfg;
  prismPrefetchPlan = builtins.fromJSON (builtins.readFile prism.system.build.aiModelPrefetchPlan);
  autoPrismCfg = lib.recursiveUpdate prismCfg {
    services.ai = {
      models = null;
      backends.llamaRouter.deployments = [
        {
          instance = "llama-router-prism";
          lifecycle = "stopped";
          runtime = "prism";
        }
      ];
    };
  };
  autoPrism = eval autoPrismCfg;
  autoPrismPrefetchPlan = builtins.fromJSON (builtins.readFile autoPrism.system.build.aiModelPrefetchPlan);
  zeroDeploymentAutoCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      models = null;
      roles.embedding = null;
      backends = {
        ollama.deployments = [];
        llamaRouter.deployments = [];
      };
    };
  };
  ollamaOnlyOnLlamaCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog.only-ollama = {
        id = "only-ollama";
        ollama = "only-ollama:1";
      };
      models = ["only-ollama"];
      roles.embedding = null;
      backends.ollama.deployments = [];
    };
  };
  invalidRuntimeTypeCfg = lib.recursiveUpdate baseConfig {
    services.ai = {
      catalog.bad-runtime = {
        id = "bad-runtime";
        llama = {
          ref = "example/bad-runtime";
          runtimes = [1];
        };
      };
      models = ["bad-runtime"];
      roles.embedding = null;
    };
  };
  duplicateCacheCfg = lib.recursiveUpdate prismCfg {
    services.ai.backends.llamaRouter.deployments = [
      {
        cacheDir = "/var/lib/test/shared-cache";
      }
      {
        cacheDir = "/var/lib/test/shared-cache";
        instance = "llama-router-prism";
        lifecycle = "stopped";
        runtime = "prism";
      }
    ];
  };
  nestedRuntimeCacheCfg = lib.recursiveUpdate prismCfg {
    services.ai.backends.llamaRouter.deployments = [
      {cacheDir = "/var/lib/test/runtime-cache";}
      {
        cacheDir = "/var/lib/test/runtime-cache/prism";
        instance = "llama-router-prism";
        lifecycle = "stopped";
        runtime = "prism";
      }
    ];
  };
  hfOllamaCacheOverlapCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends = {
      hf.cacheDir = "/var/lib/test/shared-cache";
      ollama.modelsDir = "/var/lib/test/shared-cache/ollama";
    };
  };
  ollamaLlamaCacheOverlapCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.ollama.modelsDir = "/var/lib/test/ai";
  };
  mixedRuntimeUsersCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.deployments = [
      {}
      {instance = "llama-router-prism";}
    ];
    services.podman-compose.test.instances.llama-router-prism.user = "other-user";
  };
  mixedRuntimeUsers = eval mixedRuntimeUsersCfg;
  placementCfg = {
    services.ai = {
      stack.name = "test";
      catalog = {
        first = {
          id = "first";
          llama = "example/first:Q4";
        };
        second = {
          id = "second";
          llama = "example/second:Q4";
        };
      };
      models = ["first" "second"];
      backends.llamaRouter = {
        defaults.idleTimeoutSeconds = 300;
        deployments = [
          {
            instance = "llama-router";
            models = ["first"];
          }
          {
            idleTimeoutSeconds = false;
            instance = "llama-router-prism";
            models = ["second"];
          }
        ];
      };
    };
    services.podman-compose.test = {
      user = "test-user";
      instances = baseInstances;
    };
  };
  placement = eval placementCfg;
  multiRuntimeCfg = {
    services.ai = {
      stack.name = "test";
      catalog.shared = {
        id = "shared";
        llama = {
          ref = "example/shared:Q4";
          runtimes = ["default" "prism"];
        };
      };
      models = ["shared"];
      backends.llamaRouter.deployments = [
        {instance = "llama-router";}
        {
          instance = "llama-router-prism";
          runtime = "prism";
        }
      ];
    };
    services.podman-compose.test = {
      user = "test-user";
      instances = baseInstances;
    };
  };
  multiRuntime = eval multiRuntimeCfg;
  inconsistentRuntimeCacheCfg = lib.recursiveUpdate placementCfg {
    services.ai.backends.llamaRouter.deployments = [
      {
        cacheDir = "/var/lib/test/cache-a";
        instance = "llama-router";
        models = ["first"];
      }
      {
        cacheDir = "/var/lib/test/cache-b";
        instance = "llama-router-prism";
        models = ["second"];
      }
    ];
  };
  unsafeLlamaCacheCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.llamaRouter.defaults.cacheDir = "/var/lib/test/llama/../shared";
  };
  unsafeOllamaModelsDirCfg = lib.recursiveUpdate baseConfig {
    services.ai.backends.ollama.modelsDir = "/var/lib/test/ollama models";
  };
  runtimePreservationCfg = lib.recursiveUpdate multiRuntimeCfg {
    services.ai.backends.llamaRouter.deployments = [
      {
        instance = "llama-router";
        preservedModels = ["example/default-preserved:Q4"];
      }
      {
        instance = "llama-router-prism";
        preservedModels = ["example/prism-preserved:Q4"];
        runtime = "prism";
      }
    ];
  };
  runtimePreservation = eval runtimePreservationCfg;
  isolatedPreservationCfg = lib.recursiveUpdate prismCfg {
    services.ai.backends.llamaRouter.deployments = [
      {preservedModels = [bonsaiRef];}
      {
        instance = "llama-router-prism";
        lifecycle = "stopped";
        runtime = "prism";
      }
    ];
  };
  isolatedPreservation = eval isolatedPreservationCfg;
  deviceCfg = {
    services.ai = {
      stack.name = "test";
      inherit models;
      roles.embedding = "nomic-embed-text-v15-100m";
      backends = {
        ollama.deployments = [
          {
            instance = "ollama-rocm";
            lifecycle = "manual";
          }
          {
            instance = "ollama-cpu";
            lifecycle = "manual";
          }
        ];
        llamaRouter.deployments = [
          {
            instance = "llama-nvidia";
            lifecycle = "manual";
          }
        ];
      };
    };
    services.podman-compose.test = {
      user = "test-user";
      instances = {
        ollama-rocm = {
          source = "ollama-rocm";
          exposedPorts.main.port = 12434;
        };
        ollama-cpu = {
          source = "ollama-cpu";
          exposedPorts.main.port = 11434;
        };
        llama-nvidia = {
          source = "llama-nvidia";
          exposedPorts.main.port = 13000;
        };
      };
    };
  };
  device = eval deviceCfg;
in
  assert allAssertionsHold cfg;
  assert builtins.length prefetchPlan == 14;
  assert builtins.all (entry: entry.policy == "best-effort") prefetchPlan;
  # Fast llama.cpp cache submissions precede potentially blocking Ollama pulls
  # while both remain inside one shared best-effort deadline.
  assert builtins.all (entry: entry.type == "llama") (lib.take (builtins.length llamaRefs) prefetchPlan);
  assert builtins.all (entry: entry.type == "ollama") (lib.drop (builtins.length llamaRefs) prefetchPlan);
  assert allAssertionsHold hfPrefetch;
  assert allAssertionsHold artifactOnlyHf;
  assert allAssertionsHold composedArtifactOnlyHf;
  assert !(allAssertionsHold (eval invalidHfPrefetchCfg));
  assert !(allAssertionsHold (eval invalidHfArtifactCfg));
  assert failureMessages (eval missingHfCacheCfg)
  == ["services.ai.backends.hf.cacheDir must be configured when Hugging Face artifacts are selected for prefetch."];
  assert failureMessages (eval invalidHfCachePathCfg)
  == ["services.ai.backends.hf.cacheDir must be a canonical safe absolute non-root path when configured."];
  assert failureMessages (eval unsafeHfCachePathCfg)
  == ["services.ai.backends.hf.cacheDir must be a canonical safe absolute non-root path when configured."];
  assert failureMessages (eval unsafeHfWhitespacePathCfg)
  == ["services.ai.backends.hf.cacheDir must be a canonical safe absolute non-root path when configured."];
  assert failureMessages (eval unsafeHfSpecifierPathCfg)
  == ["services.ai.backends.hf.cacheDir must be a canonical safe absolute non-root path when configured."];
  assert failureMessages (eval unsafeHfTokenPathCfg)
  == ["services.ai.backends.hf.tokenFile must be a canonical safe absolute non-root path."];
  assert failureMessages (eval missingHfOwnerCfg)
  == ["the Hugging Face cache owner must name a declared users.users entry when cacheDir is configured."];
  assert failureMessages (eval missingHfOwnerGroupCfg)
  == ["the Hugging Face cache owner group must name a declared users.groups entry when cacheDir is configured."];
  assert failureMessages (eval unfixedHfUidCfg)
  == ["the Hugging Face cache owner must resolve to a fixed numeric users.users.<name>.uid in the supported 0..2147483647 range when artifacts are selected."];
  assert failureMessages (eval unfixedHfGidCfg)
  == ["the Hugging Face cache owner group must resolve to a fixed numeric users.groups.<group>.gid in the supported 0..2147483647 range when artifacts are selected."];
  assert failureMessages (eval outOfRangeHfUidCfg)
  == ["the Hugging Face cache owner must resolve to a fixed numeric users.users.<name>.uid in the supported 0..2147483647 range when artifacts are selected."];
  assert failureMessages (eval outOfRangeHfGidCfg)
  == ["the Hugging Face cache owner group must resolve to a fixed numeric users.groups.<group>.gid in the supported 0..2147483647 range when artifacts are selected."];
  assert emptyPrefetchPlan == [];
  assert emptyPrefetch.environment.systemPackages == [];
  assert emptyPrefetch.system.systemBuilderCommands == "";
  assert stackOnly.systemd.tmpfiles.rules == [];
  assert builtins.elem
  "d /var/lib/test/empty-huggingface 0750 test-user test-user -"
  emptyPrefetch.systemd.tmpfiles.rules;
  assert nestedHfCache.systemd.tmpfiles.rules
  == [
    "d /var/lib/test/ai 0755 test-user test-user -"
    "d /var/lib/test/ai/huggingface 0750 test-user test-user -"
  ];
  assert rootHfCache.systemd.tmpfiles.rules
  == ["d /var/lib/test/ai 0750 test-user test-user -"];
  assert (builtins.head hfPrefetchPlan)
  == {
    cacheDir = "/var/lib/test/huggingface";
    id = "hf:qwen38-27b";
    include = [];
    model = "Qwen/Qwen3.8-27B";
    policy = "required";
    revision = null;
    tokenFile = null;
    type = "hf";
    owner = {
      name = "test-user";
      uid = 1234;
      group = "test-user";
      gid = 1234;
    };
  };
  assert builtins.map (entry: entry.id) (lib.take 3 hfPrefetchPlan)
  == [
    "hf:qwen38-27b"
    "hf:qwen38-27b:f16-mmproj"
    "hf:qwen38-27b:q4-mtp"
  ];
  # The backend artifact default makes true base-only, while lists still opt
  # into an exact artifact subset and [] remains the base-only spelling.
  assert builtins.map (entry: entry.id) (lib.take 4 explicitHfArtifactsPlan)
  == [
    "hf:gemma4-12b"
    "hf:gemma4-12b:bf16-eagle3"
    "hf:qwen38-27b"
    "hf:qwen38-27b-fp8"
  ];
  # Expanded selections can fetch nested files without also downloading the
  # parent's potentially much larger base repository.
  assert builtins.map (entry: entry.id) (lib.take 2 artifactOnlyHfPlan)
  == [
    "hf:qwen38-27b:f16-mmproj"
    "hf:qwen38-27b:q4-mtp"
  ];
  assert (builtins.head composedArtifactOnlyHfPlan).id == "hf:qwen38-27b:q4-mtp";
  assert builtins.elem
  "d /var/lib/test/huggingface 0750 test-user test-user -"
  hfPrefetch.systemd.tmpfiles.rules;
  # Consumer view is the single source of truth: ordered URLs, primaries,
  # OpenAI variants, and device lookup derived from the instance name.
  assert (device.services.ai.consumersFor "h").ollama.urls == ["http://h:12434" "http://h:11434"];
  assert (device.services.ai.consumersFor "h").ollama.byDevice
  == {
    rocm = ["http://h:12434"];
    cpu = ["http://h:11434"];
  };
  assert (device.services.ai.consumersFor "h").ollama.openaiByDevice.rocm == ["http://h:12434/v1"];
  assert (device.services.ai.consumersFor "h").llama.openaiByDevice.nvidia == ["http://h:13000/v1"];
  assert (builtins.head (device.services.ai.consumersFor "h").ollama.endpoints).host == "h";
  assert (builtins.head (device.services.ai.consumersFor "h").llama.endpoints).runtime == "default";
  assert device.services.ai.backends.ollama.endpoints
  == [
    {
      instance = "ollama-rocm";
      port = 12434;
      host = null;
      device = "rocm";
      inherit modelIds;
    }
    {
      instance = "ollama-cpu";
      port = 11434;
      host = null;
      device = "cpu";
      inherit modelIds;
    }
  ];
  assert device.services.ai.backends.llamaRouter.deploymentsInfo.llama-nvidia.port == 13000;
  assert device.services.ai.backends.llamaRouter.deploymentsInfo.llama-nvidia.runtime == "default";
  assert device.services.ai.backends.llamaRouter.deploymentsInfo.llama-nvidia.modelIds == modelIds;
  # A llama-only host reads its own consumer view; the absent Ollama primary is
  # lazy and throws only when a consumer actually requires it.
  assert ((eval llamaOnlyAutoCfg).services.ai.consumersFor "h").llama.urls == ["http://h:11000"];
  assert !(builtins.tryEval ((eval llamaOnlyAutoCfg).services.ai.consumersFor "h").ollama.default).success;
  # Consumer addressing spans every declared llama.cpp runtime in deployment
  # order. Stopped deployments stay addressable but are not probed for warmup.
  assert (prism.services.ai.consumersFor "h").llama.urls == ["http://h:11000" "http://h:13000"];
  assert builtins.map (endpoint: endpoint.runtime) (prism.services.ai.consumersFor "h").llama.endpoints
  == ["default" "prism"];
  assert builtins.map (endpoint: endpoint.modelIds) (prism.services.ai.consumersFor "h").llama.endpoints
  == [modelIds ["bonsai2:27b"]];
  assert (autoPrism.services.ai.consumersFor "h").llama.urls == ["http://h:13000"];
  assert (builtins.head (autoPrism.services.ai.consumersFor "h").llama.endpoints).runtime == "prism";
  assert !(builtins.any (entry: lib.hasPrefix "llama:prism:" entry.id) prismPrefetchPlan);
  assert !(builtins.any (entry: entry.type == "llama") autoPrismPrefetchPlan);
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
  assert cfg.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.port == 11000;
  assert cfg.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.requiredModels == llamaRefs;
  assert cfg.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.modelPresets."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
  == {
    alias = "nomic-embed-text";
    embeddings = "true";
    poll = "0";
  };
  assert cfg.services.ai.resolvedModels == models;
  # models = null keeps the option null but resolves the servable selection.
  assert allAssertionsHold (eval autoModelsCfg);
  assert (eval autoModelsCfg).services.ai.models == null;
  assert (eval autoModelsCfg).services.ai.resolvedModels == autoServable;
  assert !(builtins.elem "bonsai2-27b" autoServable);
  assert allAssertionsHold (eval autoPrismCfg);
  assert builtins.length (eval autoPrismCfg).services.ai.resolvedModels == 15;
  assert allAssertionsHold (eval zeroDeploymentAutoCfg);
  assert (eval zeroDeploymentAutoCfg).services.ai.resolvedModels == [];
  assert allAssertionsHold (eval llamaOnlyAutoCfg);
  assert (eval llamaOnlyAutoCfg).services.ai.resolvedModels == ["llama-only"];
  assert (eval llamaOnlyAutoCfg).services.ai.backends.llamaRouter.deploymentsInfo.llama-router.requiredModels == ["example/llama-only:Q4"];
  assert allAssertionsHold (eval hfOnlyCfg);
  assert (eval hfOnlyCfg).services.ai.resolvedModels == ["hf-only"];
  assert allAssertionsHold customProjectionEval;
  assert customProjectionEval.services.ai.catalog.custom.id == "custom-model";
  assert customProjectionEval.services.ai.backends.ollama.requiredModels == ["custom/model:1"];
  assert !customProjection.moduleConfig.backends.hf.prefetchDefaults.artifacts;
  assert !customProjectionEval.services.ai.backends.hf.prefetchDefaults.artifacts;
  assert customProjectionEval.services.ai.roles.main == "custom";
  assert cfg.services.podman-compose.test.instances.ollama.state == "stopped";
  assert cfg.services.podman-compose.test.instances.ollama-2.autoStart == false;
  assert cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text != "";
  # Idle sleep is opt-in: the default emits no [*] section, so models stay
  # resident until LRU eviction (pre-existing behavior).
  assert !(lib.hasInfix "sleep-idle-seconds" cfg.services.podman-compose.test.instances.llama-router.files."models.ini".text);
  assert lib.hasInfix "[*]\nsleep-idle-seconds = 300\n" (eval idleTimeoutCfg).services.podman-compose.test.instances.llama-router.files."models.ini".text;
  assert builtins.any
  (lib.hasInfix "start --no-block test-ollama-models-pull.service")
  cfg.systemd.user.services.special-ollama.serviceConfig.ExecStartPost;
  assert builtins.any
  (lib.hasInfix "start --no-block test-llama-router-models-load.service")
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
  assert (eval customLlamaCacheCfg).services.ai.backends.llamaRouter.deploymentsInfo.llama-router.cacheDir == "/mnt/models/llama-router";
  assert builtins.elem
  "d /mnt/models/llama-router 0755 test-user test-user -"
  (eval customLlamaCacheCfg).systemd.tmpfiles.rules;
  assert !(builtins.any
    (rule: lib.hasPrefix "d /mnt " rule || lib.hasPrefix "d /mnt/models " rule)
    (eval customLlamaCacheCfg).systemd.tmpfiles.rules);
  assert (eval autoCfg).services.ai.backends.ollama.readyTarget == "special-ollama-ready.target";
  assert builtins.elem
  "custom-llama-router-ready.target"
  (eval autoCfg).systemd.user.services."test-llama-router-models".after;
  # Fork runtime: separate cache, separate models.ini, separate reconciler.
  assert allAssertionsHold prism;
  assert prism.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.requiredModels == [bonsaiRef];
  assert prism.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.modelIds == ["bonsai2:27b"];
  assert prism.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.cacheDir == "/var/lib/test/ai/llama-router-prism";
  assert !(builtins.elem bonsaiRef prism.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.requiredModels);
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
  (lib.hasInfix "start --no-block test-llama-router-prism-models-load.service")
  prism.systemd.user.services.custom-llama-router-prism.serviceConfig.ExecStartPost;
  # Per-deployment placement and idle policy render separate models.ini files,
  # while one runtime reconciler owns the union in their shared cache.
  assert allAssertionsHold placement;
  assert placement.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.models == ["first"];
  assert placement.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.models == ["second"];
  assert lib.hasInfix "[first]" placement.services.podman-compose.test.instances.llama-router.files."models.ini".text;
  assert !(lib.hasInfix "[second]" placement.services.podman-compose.test.instances.llama-router.files."models.ini".text);
  assert lib.hasInfix "sleep-idle-seconds = 300" placement.services.podman-compose.test.instances.llama-router.files."models.ini".text;
  assert lib.hasInfix "[second]" placement.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text;
  assert !(lib.hasInfix "sleep-idle-seconds" placement.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text);
  assert lib.hasInfix
  "example/first:Q4 example/second:Q4"
  placement.systemd.user.services."test-llama-router-models".serviceConfig.ExecStart;
  # The same catalog model may be deployed by several compatible runtimes;
  # each runtime retains its isolated cache and ownership state.
  assert allAssertionsHold multiRuntime;
  assert multiRuntime.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.requiredModels == ["example/shared:Q4"];
  assert multiRuntime.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.requiredModels == ["example/shared:Q4"];
  assert multiRuntime.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.cacheDir == "/var/lib/test/ai/llama-router";
  assert multiRuntime.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.cacheDir == "/var/lib/test/ai/llama-router-prism";
  assert runtimePreservation.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.preservedModels
  == ["example/default-preserved:Q4"];
  assert runtimePreservation.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.preservedModels
  == ["example/prism-preserved:Q4"];
  assert allAssertionsHold isolatedPreservation;
  assert isolatedPreservation.services.ai.backends.llamaRouter.deploymentsInfo.llama-router.preservedModels == [bonsaiRef];
  assert isolatedPreservation.services.ai.backends.llamaRouter.deploymentsInfo.llama-router-prism.preservedModels == [];
  assert !(allAssertionsHold (eval badRoleCfg));
  assert !(allAssertionsHold (eval missingInstanceCfg));
  assert failureMessages (eval missingInstancesCfg)
  == [
    "services.ai.backends.llamaRouter: deployment missing-a has no matching podman-compose instance."
    "services.ai.backends.llamaRouter: deployment missing-b has no matching podman-compose instance."
  ];
  assert !(allAssertionsHold (eval crossBackendNameCollisionCfg));
  assert !(allAssertionsHold (eval crossBackendPortCollisionCfg));
  assert !(allAssertionsHold (eval missingStackCfg));
  assert !(allAssertionsHold (eval unservedCfg));
  assert !(allAssertionsHold (eval unknownRuntimeCfg));
  assert !(allAssertionsHold (eval ollamaOnlyOnLlamaCfg));
  assert !(allAssertionsHold (eval invalidRuntimeTypeCfg));
  assert failureMessages (eval unsafeLlamaCacheCfg)
  == ["services.ai.backends.llamaRouter.deployments: cacheDir must resolve to a canonical safe absolute path: llama-router"];
  assert failureMessages (eval unsafeOllamaModelsDirCfg)
  == ["services.ai.backends.ollama.modelsDir must be a canonical safe absolute path when configured."];
  assert failureMessages (eval duplicateCacheCfg)
  == [
    "services.ai: managed backend storage paths must be pairwise non-overlapping: llama.default=/var/lib/test/shared-cache <-> llama.prism=/var/lib/test/shared-cache"
  ];
  assert failureMessages (eval nestedRuntimeCacheCfg)
  == [
    "services.ai: managed backend storage paths must be pairwise non-overlapping: llama.default=/var/lib/test/runtime-cache <-> llama.prism=/var/lib/test/runtime-cache/prism"
  ];
  assert failureMessages (eval hfOllamaCacheOverlapCfg)
  == [
    "services.ai: managed backend storage paths must be pairwise non-overlapping: hf=/var/lib/test/shared-cache <-> ollama=/var/lib/test/shared-cache/ollama"
  ];
  assert failureMessages (eval ollamaLlamaCacheOverlapCfg)
  == [
    "services.ai: managed backend storage paths must be pairwise non-overlapping: ollama=/var/lib/test/ai <-> llama.default=/var/lib/test/ai/llama-router"
  ];
  assert failureMessages mixedRuntimeUsers
  == [
    "services.ai.backends.llamaRouter.deployments: runtime default must resolve to one systemd user."
  ];
  assert failureMessages (eval inconsistentRuntimeCacheCfg)
  == [
    "services.ai.backends.llamaRouter.deployments: deployments sharing a runtime must resolve to one cacheDir: default"
  ];
  assert mixedRuntimeUsers.services.podman-compose.test.instances.llama-router.files."models.ini".text != "";
  assert mixedRuntimeUsers.services.podman-compose.test.instances.llama-router-prism.files."models.ini".text != "";
    pkgs.runCommand "ai-module-test" {
      nativeBuildInputs = [hfPrefetchRunner pkgs.jq];
    } ''
      owner="$(id -un)"
      jq -cn \
        --arg cache "$PWD/cache" \
        --arg user "$owner" \
        '[{
          id: "hf:closure-test",
          type: "hf",
          model: "example/closure-test",
          revision: null,
          include: [],
          cacheDir: $cache,
          tokenFile: ($cache + "-missing-token"),
          user: $user,
          policy: "required"
        }]' > plan.json
      if AI_MODEL_PREFETCH_PLAN="$PWD/plan.json" ai-model-prefetch-all; then
        echo "closure probe unexpectedly succeeded" >&2
        exit 1
      fi
      test ! -e "$PWD/cache"
      touch $out
    ''
