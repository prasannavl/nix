let
  backendLib = import ./backends.nix;
  defaultCatalog = import ./catalog.nix;
in rec {
  # Catalog keys servable by the declared backends, in catalog order.
  #
  # A model is servable when its llama.cpp runtime is declared, or when it
  # carries an Ollama reference and an Ollama backend is declared. Entries
  # without a llama reference select the `default` runtime, so an Ollama-only
  # host needs no llama runtime entry.
  servableModels = {
    catalog ? defaultCatalog,
    ollama ? false,
    runtimes ? {},
  }:
    builtins.filter
    (key: let
      entry = catalog.${key};
    in
      builtins.elem (backendLib.llamaRuntime entry) (builtins.attrNames runtimes)
      || (ollama && backendLib.backendConfig "ollama" entry != null))
    (builtins.attrNames catalog);

  # OpenAI-compatible {served id -> upstream HF repo} map.
  catalogById = catalog:
    builtins.listToAttrs
    (map (model: {
        name = model.id;
        value = model.hf;
      })
      (builtins.attrValues catalog));

  # Catalog ids flagged for default Web UI pinning.
  pinnedModelIds = catalog:
    map (model: model.id) (builtins.filter (model: model.pinned or false) (builtins.attrValues catalog));

  # Project a stack service registry into per-service HTTP API records.
  mkServiceApis = {
    registry,
    services,
  }:
    builtins.mapAttrs
    (_: name: let
      baseUrl = registry.urlPrivateFor "http" name "http";
    in {
      port = registry.portFor name "http";
      inherit baseUrl;
      openAiBaseUrl = "${baseUrl}/v1";
    })
    services;

  # Resolve one host AI policy into the generic, repo-agnostic projection.
  #
  # `models = null` (the default) selects every model servable by the declared
  # backends; an explicit list is used verbatim. `defaults` maps each role to
  # its catalog entry so repositories can read `defaults.<role>.id` directly.
  # Service- and consumer-specific views (OpenAI proxy, Web UI, Graphiti,
  # storage layout) stay in the repository layer; the helpers above keep them
  # thin.
  mkProjection = {
    catalog ? defaultCatalog,
    models ? null,
    roles ? {},
    backends ? {
      ollama.deployments = [];
      llamaRouter.runtimes = {};
    },
    apiServices ? {},
  }: let
    resolvedModels =
      if models == null
      then
        servableModels {
          inherit catalog;
          ollama = (backends.ollama.deployments or []) != [];
          runtimes = backends.llamaRouter.runtimes or {};
        }
      else models;
    defaults =
      builtins.mapAttrs
      (_: key:
        if key == null
        then null
        else catalog.${key})
      roles;
  in {
    inherit catalog roles defaults;
    models = resolvedModels;
    mkApi = registry:
      mkServiceApis {
        inherit registry;
        services = apiServices;
      };
    aiServices = {
      models = resolvedModels;
      inherit roles backends;
    };
  };
}
