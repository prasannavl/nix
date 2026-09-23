{pkgs}: let
  projectionLib = import ../projection.nix;
  catalog = import ../catalog.nix;
  roles = {
    main = "gemma4-26b";
    smallTask = "gemma4-e2b";
    embedding = "nomic-embed-text";
  };
  backends = {
    ollama = {
      active = true;
      deployments = [{lifecycle = "auto";}];
      modelsDir = "/models";
      ports = [11434];
      requiredModels = ["derived"];
    };
    llamaRouter = {
      active = true;
      runtimes.default = {
        active = true;
        cacheDir = "/cache";
        deployments = [{}];
        idleTimeoutSeconds = 300;
        modelPresets = {derived = {};};
        ports = [11000];
        preservedModels = ["example/preserved:Q4"];
      };
      runtimesInfo.default.active = true;
    };
  };
  autoProjection = projectionLib.mkProjection {
    inherit backends catalog roles;
    apiServices.ollama = "ollama";
  };
  explicitProjection = projectionLib.mkProjection {
    inherit catalog;
    models = ["gemma4-26b" "nomic-embed-text"];
    roles = {
      main = "gemma4-26b";
      embedding = "nomic-embed-text";
    };
  };
  emptyProjection = projectionLib.mkProjection {inherit catalog;};
  backendShapeCatalog = {
    llama-only = {
      id = "llama";
      llama = "example/llama";
    };
    neither = {
      id = "neither";
      hf = "example/neither";
    };
    ollama-only = {
      id = "ollama";
      ollama = "ollama";
    };
  };
  llamaOnlyPolicy = projectionLib.resolvePolicy {
    catalog = backendShapeCatalog;
    backends.llamaRouter.runtimes.default.deployments = [{}];
  };
  noRuntimePolicy = projectionLib.resolvePolicy {
    catalog.only = {
      id = "only";
      llama = "example/only:Q4";
    };
    models = ["only"];
  };
  hybridPolicy = projectionLib.resolvePolicy {
    catalog.dual = {
      id = "dual";
      ollama = "dual";
      llama = "example/dual:Q4";
    };
    models = ["dual"];
    backends = {
      ollama.deployments = [{}];
      llamaRouter.runtimes.prism.deployments = [{}];
    };
  };
  duplicatePolicy = projectionLib.resolvePolicy {
    catalog = {
      first = {
        id = "duplicate";
        ollama = "shared";
        llama = "example/shared:Q4";
      };
      second = {
        id = "duplicate";
        ollama = "shared";
        llama = "example/shared:Q4";
      };
    };
    backends = {
      ollama.deployments = [{}];
      llamaRouter.runtimes.default.deployments = [{}];
    };
  };
  invalidDormantPolicy = projectionLib.resolvePolicy {
    catalog = {
      selected = {
        id = "selected";
        ollama = "selected";
      };
      dormant = {
        id = "dormant";
        llama = "not-a-hugging-face-reference";
      };
    };
    models = ["selected"];
    backends.ollama.deployments = [{}];
  };
  badRolePolicy = projectionLib.resolvePolicy {
    catalog.only = {
      id = "only";
      ollama = "only";
    };
    models = ["only"];
    roles.main = "missing";
    backends.ollama.deployments = [{}];
  };
  malformedRolePolicy = projectionLib.resolvePolicy {
    catalog.only = {
      id = "only";
      ollama = "only";
    };
    models = ["only"];
    roles.main = {};
    backends.ollama.deployments = [{}];
  };
  invalidPresetPolicy = preset:
    projectionLib.resolvePolicy {
      catalog.only = {
        id = "only";
        llama = {
          ref = "example/only:Q4";
          inherit preset;
        };
      };
      models = ["only"];
      backends.llamaRouter.runtimes.default.deployments = [{}];
    };
  diagnosticCodes = policy: builtins.map (entry: entry.code) policy.diagnostics;
  invalidProjection = value: builtins.tryEval (builtins.deepSeq value true);
in
  # Backend admission is derived by the resolver, including auto-selection.
  assert llamaOnlyPolicy.valid;
  assert llamaOnlyPolicy.models == ["llama-only"];
  assert llamaOnlyPolicy.runtimes.default.requiredModels == ["example/llama"];
  assert diagnosticCodes noRuntimePolicy == ["unknown-llama-runtime"];
  # An Ollama deployment may serve a dual-backend entry even when its llama
  # runtime is absent on this host.
  assert hybridPolicy.valid;
  assert hybridPolicy.ollama.requiredModels == ["dual"];
  assert hybridPolicy.runtimes.prism.requiredModels == [];
  # Catalog identity admission is global and fail-closed, not selection-scoped.
  assert diagnosticCodes duplicatePolicy
  == [
    "duplicate-model-id"
    "duplicate-ollama-reference"
    "duplicate-llama-reference"
  ];
  assert diagnosticCodes invalidDormantPolicy == ["invalid-llama-reference"];
  assert !invalidDormantPolicy.valid;
  # Presets use the same schema here and in the reconciler renderer.
  assert diagnosticCodes (invalidPresetPolicy {threads = "";}) == ["invalid-llama-preset"];
  assert diagnosticCodes (invalidPresetPolicy {threads = "a\nb";}) == ["invalid-llama-preset"];
  assert diagnosticCodes (invalidPresetPolicy {"bad key" = "1";}) == ["invalid-llama-preset"];
  assert diagnosticCodes (invalidPresetPolicy {alias = "override";}) == ["invalid-llama-preset"];
  # Bad roles are diagnostics and safe null defaults, never raw attr errors.
  assert malformedRolePolicy.defaults.main == null;
  assert diagnosticCodes malformedRolePolicy == ["invalid-role"];
  assert badRolePolicy.defaults.main == null;
  assert diagnosticCodes badRolePolicy == ["invalid-role"];
  # Explicit selections are used verbatim; null selects the deployed set.
  assert explicitProjection.models == ["gemma4-26b" "nomic-embed-text"];
  assert explicitProjection.defaults.main.id == "gemma4:26b";
  assert builtins.length autoProjection.models == 14;
  assert !(builtins.elem "bonsai-2-27b" autoProjection.models);
  assert autoProjection.defaults.smallTask.id == "gemma4:e2b";
  assert autoProjection.valid;
  assert autoProjection.ollama.requiredModels != [];
  assert autoProjection.runtimes.default.requiredModels != [];
  # The cross-repository handoff is complete and contains declarations only.
  assert autoProjection.moduleConfig.catalog == catalog;
  assert autoProjection.moduleConfig.models == autoProjection.models;
  assert autoProjection.moduleConfig.roles == roles;
  assert autoProjection.moduleConfig.backends.ollama
  == {
    deployments = [{lifecycle = "auto";}];
    modelsDir = "/models";
  };
  assert autoProjection.moduleConfig.backends.llamaRouter.runtimes.default
  == {
    cacheDir = "/cache";
    deployments = [{}];
    idleTimeoutSeconds = 300;
    preservedModels = ["example/preserved:Q4"];
  };
  assert !(autoProjection.moduleConfig.backends.ollama ? active);
  assert !(autoProjection.moduleConfig.backends.llamaRouter ? runtimesInfo);
  # Unset roles degrade to null/empty values rather than failing evaluation.
  assert emptyProjection.valid;
  assert emptyProjection.defaults == {};
  assert emptyProjection.models == [];
  # Generic helpers keep repository views thin.
  assert (projectionLib.catalogById catalog)."gemma4:26b" == "google/gemma-4-26B-A4B-it";
  assert builtins.elem "gemma4:26b" (projectionLib.pinnedModelIds catalog);
  assert !(builtins.elem "nomic-embed-text" (projectionLib.pinnedModelIds catalog));
  assert (projectionLib.mkServiceApis {
    registry = {
      urlPrivateFor = _: _: _: "http://x";
      portFor = _: _: 7;
    };
    services = {ollama = "ollama";};
  }).ollama
  == {
    port = 7;
    baseUrl = "http://x";
    openAiBaseUrl = "http://x/v1";
  };
  assert (autoProjection.mkApi {
    urlPrivateFor = _: _: _: "http://y";
    portFor = _: _: 9;
  }).ollama.port
  == 9;
  assert !(invalidProjection (projectionLib.catalogById {
    first = {
      id = "same";
      hf = "example/first";
    };
    second = {
      id = "same";
      hf = "example/second";
    };
  })).success;
  assert !(invalidProjection (projectionLib.catalogById {
    missing-hf.id = "missing-hf";
  })).success;
  # Consumers: `host` per endpoint overrides the default host, so one backend
  # can span hosts; order is preserved and native/OpenAI primaries are exposed.
  assert projectionLib.mkConsumers {
    defaultHost = "default";
    ollamaEndpoints = [
      {port = 1;}
      {
        port = 2;
        host = "remote";
      }
    ];
    llamaEndpoints = [{port = 3;}];
  }
  == {
    ollama = {
      endpoints = [
        {
          port = 1;
          host = "default";
          url = "http://default:1";
        }
        {
          port = 2;
          host = "remote";
          url = "http://remote:2";
        }
      ];
      urls = ["http://default:1" "http://remote:2"];
      openaiUrls = ["http://default:1/v1" "http://remote:2/v1"];
      default = "http://default:1";
      openaiDefault = "http://default:1/v1";
      byDevice = {};
      openaiByDevice = {};
    };
    llama = {
      endpoints = [
        {
          port = 3;
          host = "default";
          url = "http://default:3";
        }
      ];
      urls = ["http://default:3"];
      openaiUrls = ["http://default:3/v1"];
      apiKeys = ["ollama"];
      default = "http://default:3";
      openaiDefault = "http://default:3/v1";
      byDevice = {};
      openaiByDevice = {};
    };
  };
  # Device lookup is the single source for single-endpoint consumers.
  assert (projectionLib.mkConsumers {
    ollamaEndpoints = [
      {
        device = "rocm";
        port = 1;
      }
      {
        device = "cpu";
        port = 2;
      }
    ];
  }).ollama.openaiByDevice
  == {
    rocm = ["http://127.0.0.1:1/v1"];
    cpu = ["http://127.0.0.1:2/v1"];
  };
  # A required primary with no deployed endpoint fails with one clear message.
  assert !(builtins.tryEval (projectionLib.mkConsumers {}).ollama.default).success;
  # Endpoints may be fully resolved URLs (registry-driven consumers).
  assert (projectionLib.mkConsumers {
    ollamaEndpoints = [{url = "http://registry:11434";}];
    llamaEndpoints = [{url = "http://registry:11436";}];
  }).llama.openaiDefault
  == "http://registry:11436/v1";
    pkgs.runCommand "ai-projection-test" {} ''
      touch $out
    ''
