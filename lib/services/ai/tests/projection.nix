{pkgs}: let
  projectionLib = import ../projection.nix;
  catalog = import ../catalog.nix;

  roles = {
    main = "gemma4-26b";
    smallTask = "gemma4-e2b";
    embedding = "nomic-embed-text";
  };

  autoProjection = projectionLib.mkProjection {
    inherit catalog roles;
    models = null;
    backends = {
      ollama.deployments = [
        {
          lifecycle = "auto";
        }
      ];
      llamaRouter.runtimes.default = {
        deployments = [{}];
        idleTimeoutSeconds = 300;
      };
    };
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
  badRolePolicy = projectionLib.resolvePolicy {
    catalog.only = {
      id = "only";
      ollama = "only";
    };
    models = ["only"];
    roles.main = "missing";
    backends.ollama.deployments = [{}];
  };
  hybridPolicy = projectionLib.resolvePolicy {
    catalog = {
      dual = {
        id = "dual";
        ollama = "dual";
        llama = "example/dual:Q4";
      };
      prism = {
        id = "prism";
        llama = {
          ref = "example/prism:Q4";
          runtime = "prism";
        };
      };
    };
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
  malformedRolePolicy = projectionLib.resolvePolicy {
    catalog.only = {
      id = "only";
      ollama = "only";
    };
    models = ["only"];
    roles.main = {};
    backends.ollama.deployments = [{}];
  };
  diagnosticCodes = policy: builtins.map (entry: entry.code) policy.diagnostics;
  invalidProjection = value: builtins.tryEval (builtins.deepSeq value true);
in
  # servableModels follows the declared backends.
  assert builtins.length (projectionLib.servableModels {
    inherit catalog;
    ollama = true;
    runtimes = {};
  })
  == 15;
  assert !(builtins.elem "bonsai-2-27b" (projectionLib.servableModels {
    inherit catalog;
    ollama = true;
    runtimes = {};
  }));
  assert !(builtins.elem "bonsai-2-27b" (projectionLib.servableModels {
    inherit catalog;
    ollama = true;
    runtimes = {default = {};};
  }));
  assert builtins.elem "bonsai-2-27b" (projectionLib.servableModels {
    inherit catalog;
    ollama = false;
    runtimes.prism.deployments = [{}];
  });
  # Backend presence requires a valid reference and an actual deployment.
  assert projectionLib.servableModels {
    catalog = backendShapeCatalog;
    ollama = false;
    runtimes.default.deployments = [{}];
  }
  == ["llama-only"];
  assert projectionLib.servableModels {
    catalog = backendShapeCatalog;
    ollama = false;
    runtimes.default = {};
  }
  == [];
  # Policy partitions by deployed membership. An unused default-runtime
  # reference must not invalidate a model that Ollama serves.
  assert hybridPolicy.valid;
  assert hybridPolicy.models == ["dual" "prism"];
  assert hybridPolicy.ollama.requiredModels == ["dual"];
  assert hybridPolicy.runtimes.prism.requiredModels == ["example/prism:Q4"];
  assert diagnosticCodes duplicatePolicy
  == [
    "duplicate-model-id"
    "duplicate-ollama-reference"
    "duplicate-llama-reference"
  ];
  assert malformedRolePolicy.defaults.main == null;
  assert diagnosticCodes malformedRolePolicy == ["invalid-role"];
  assert llamaOnlyPolicy.valid;
  assert llamaOnlyPolicy.models == ["llama-only"];
  assert llamaOnlyPolicy.runtimes.default.requiredModels == ["example/llama"];
  assert badRolePolicy.defaults.main == null;
  assert diagnosticCodes badRolePolicy == ["invalid-role"];
  # Ollama and a fork runtime can jointly serve catalog entries without the
  # entries' unrelated default-runtime references becoming errors.
  assert builtins.length (projectionLib.servableModels {
    inherit catalog;
    ollama = true;
    runtimes.prism.deployments = [{}];
  })
  == 16;
  assert projectionLib.servableModels {
    inherit catalog;
    ollama = false;
    runtimes = {};
  }
  == [];
  # Explicit selections are used verbatim.
  assert explicitProjection.models == ["gemma4-26b" "nomic-embed-text"];
  assert explicitProjection.defaults.main.id == "gemma4:26b";
  # null models resolves to the servable set for the declared backends.
  assert builtins.length autoProjection.models == 15;
  assert !(builtins.elem "bonsai-2-27b" autoProjection.models);
  assert autoProjection.defaults.smallTask.id == "gemma4:e2b";
  assert autoProjection.valid;
  assert autoProjection.ollama.requiredModels != [];
  assert autoProjection.runtimes.default.requiredModels != [];
  assert autoProjection.aiServices.models == autoProjection.models;
  assert autoProjection.aiServices.roles == roles;
  # Unset roles degrade to null instead of failing evaluation.
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
  # Catalog and role diagnostics are shared by every pure policy projection.
  assert builtins.elem "invalid-llama-runtime" (diagnosticCodes (projectionLib.mkProjection {
    catalog.bad = {
      id = "bad";
      llama = {
        ref = "example/bad";
        runtime = 1;
      };
    };
    models = ["bad"];
  }));
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
  assert builtins.elem "invalid-role" (diagnosticCodes (projectionLib.mkProjection {
    catalog.good = {
      id = "good";
      hf = "example/good";
    };
    models = ["good"];
    roles.main = "typo";
  }));
  assert builtins.elem "invalid-role" (diagnosticCodes (projectionLib.mkProjection {
    catalog = {
      first = {
        id = "first";
        hf = "example/first";
      };
      second = {
        id = "second";
        hf = "example/second";
      };
    };
    models = ["first"];
    roles.main = "second";
  }));
    pkgs.runCommand "ai-projection-test" {} ''
      touch $out
    ''
