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
      llamaRouter.runtimes.default.idleTimeoutSeconds = 300;
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
    runtimes = {prism = {};};
  });
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
  assert autoProjection.aiServices.models == autoProjection.models;
  assert autoProjection.aiServices.roles == roles;
  # Unset roles degrade to null instead of failing evaluation.
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
    pkgs.runCommand "ai-projection-test" {} ''
      touch $out
    ''
