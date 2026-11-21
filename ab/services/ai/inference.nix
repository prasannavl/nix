let
  backendLib = import ./backends.nix;
  names = builtins.attrNames;
  all = builtins.all;
  elem = builtins.elem;
  mapAttrs = builtins.mapAttrs;
  text = value: builtins.isString value && value != "" && builtins.match "[^[:cntrl:]]+" value != null;
  ref = value: text value && builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" value != null;
  unique = values:
    builtins.length values
    == builtins.length (names (builtins.listToAttrs (builtins.map (value: {
        name = value;
        value = true;
      })
      values)));
  stringList = values: builtins.isList values && all text values && unique values;
  shape = allowed: value: builtins.isAttrs value && all (key: elem key allowed) (names value);
  fields = predicate: value: builtins.isAttrs value && all (key: ref key && predicate value.${key}) (names value);
  stripSlash = value: let
    match = builtins.match "(.*)/" value;
  in
    if match == null
    then value
    else builtins.head match;
  validBase = remote: value:
    text value
    && builtins.match "${
      if remote
      then "https"
      else "https?"
    }://([A-Za-z0-9][A-Za-z0-9.-]*|[[][0-9A-Fa-f:]+[]])(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/?"
    value
    != null
    && builtins.match ".*/[.][.]?(/.*)?" value == null;
  providerValid = value:
    shape ["endpoint" "apiBases" "auth" "accountRef"] value
    && elem (value.auth or null) ["none" "bearer"]
    && ((value.accountRef or null) == null || ref value.accountRef)
    && (
      if value ? endpoint
      then !(value ? apiBases) && ref value.endpoint
      else value ? apiBases && value.apiBases != {} && shape ["openai" "ollama"] value.apiBases && all (validBase true) (builtins.attrValues value.apiBases)
    );
  targetValid = value:
    shape ["provider" "catalogKey" "model"] value
    && ref (value.provider or null)
    && (
      if value ? catalogKey
      then !(value ? model) && ref value.catalogKey
      else text (value.model or null)
    );
  consumerValid = value:
    shape ["roles" "choices" "credentials"] value
    && fields (selection: selection == null || ref selection) (value.roles or {})
    && fields (selections: stringList selections && all ref selections) (value.choices or {})
    && fields ref (value.credentials or {});
  problem = code: message: {inherit code message;};
  when = condition: code: message:
    if condition
    then [(problem code message)]
    else [];
in rec {
  # API metadata is not a runtime gateway or an app-contract registry.
  resolveInference = {
    hosting,
    inference ? {},
    localEndpoints ? {},
    requests,
  }: let
    providers = inference.providers or {};
    targets = inference.targets or {};
    defaults = inference.defaults or {};
    consumers = inference.consumers or {};
    shapesValid =
      shape ["providers" "targets" "defaults" "consumers"] inference
      && fields providerValid providers
      && fields targetValid targets
      && fields ref defaults
      && fields consumerValid consumers
      && fields (roles: stringList roles && roles != [] && all ref roles) requests;
    referencesValid =
      shapesValid
      && all (name: let
        target = targets.${name};
      in
        providers ? ${target.provider}
        && (providers.${target.provider} ? endpoint) == (target ? catalogKey)) (names targets)
      && all (selection: targets ? ${selection}) (builtins.attrValues defaults)
      && all (name: let
        consumer = consumers.${name};
      in
        all (selection: selection == null || targets ? ${selection}) (builtins.attrValues (consumer.roles or {}))
        && all (choices: all (selection: targets ? ${selection}) choices) (builtins.attrValues (consumer.choices or {}))
        && all (provider: providers ? ${provider} && providers.${provider}.auth == "bearer") (names (consumer.credentials or {}))) (names consumers);
    declarationErrors =
      when (!shapesValid) "invalid-inference-shape" "Inference declarations contain an invalid field, type or reference name."
      ++ when (shapesValid && !referencesValid) "invalid-inference-reference" "Inference declarations reference an unknown target/provider, mismatch provider/model kinds or assign a no-auth credential slot.";
    endpointList = builtins.concatMap (backend: builtins.map (endpoint: endpoint // {inherit backend;}) localEndpoints.${backend}) (names localEndpoints);
    endpointsValid =
      shape ["ollama" "llama"] localEndpoints
      && all (backend:
        builtins.isList localEndpoints.${backend}
        && all (endpoint: builtins.isAttrs endpoint && ref (endpoint.instance or null) && validBase false (endpoint.url or null) && stringList (endpoint.modelIds or null)) localEndpoints.${backend}) (names localEndpoints);
    endpointNames = builtins.map (endpoint: endpoint.instance) endpointList;
    contextErrors =
      if shapesValid && requests == {}
      then []
      else
        when (!endpointsValid) "invalid-inference-endpoints" "Inference endpoints require unique instance identities, canonical native bases and exact model admission."
        ++ when (endpointsValid && !unique endpointNames) "duplicate-inference-endpoint" "Inference deployment instance identities must be unique across backends.";
    endpointMap = builtins.listToAttrs (builtins.map (endpoint: {
        name = endpoint.instance;
        value = endpoint;
      })
      endpointList);
    candidate = consumer: targetName: let
      target = targets.${targetName};
      provider = providers.${target.provider};
      credential = (consumer.credentials or {}).${target.provider} or null;
      endpoint =
        if provider ? endpoint
        then endpointMap.${provider.endpoint} or null
        else null;
      entry =
        if target ? catalogKey
        then hosting.catalog.${target.catalogKey} or null
        else null;
      backend =
        if endpoint == null
        then null
        else endpoint.backend;
      wireModel =
        if entry == null || backend == null
        then null
        else if backend == "ollama"
        then (backendLib.backendConfig "ollama" entry).ref or null
        else entry.id or null;
      admitted =
        if provider ? endpoint
        then
          endpoint
          != null
          && entry != null
          && elem target.catalogKey hosting.models
          && text wireModel
          && elem wireModel endpoint.modelIds
        else target ? model;
      credentialValid = provider.auth == "none" || credential != null;
      apis =
        if provider ? endpoint
        then
          {
            openai = {
              baseUrl = "${stripSlash endpoint.url}/v1";
              model = wireModel;
            };
          }
          // (
            if backend == "ollama"
            then {
              ollama = {
                baseUrl = stripSlash endpoint.url;
                model = wireModel;
              };
            }
            else {}
          )
        else
          mapAttrs (_: baseUrl: {
            baseUrl = stripSlash baseUrl;
            model = target.model;
          })
          provider.apiBases;
    in
      if !admitted || !credentialValid
      then null
      else {
        target = targetName;
        provider = target.provider;
        accountRef = provider.accountRef or null;
        catalogKey = target.catalogKey or null;
        capabilities =
          if entry == null
          then []
          else entry.capabilities or [];
        inherit apis;
        auth = {
          kind = provider.auth;
          credentialRef = credential;
        };
      };
    resolveConsumer = name: let
      consumer = consumers.${name};
      roles = requests.${name};
      selections = builtins.listToAttrs (builtins.map (role: {
          name = role;
          value =
            if (consumer.roles or {}) ? ${role}
            then consumer.roles.${role}
            else defaults.${role} or "";
        })
        roles);
      candidates = mapAttrs (_: selection:
        if selection == null || selection == ""
        then null
        else candidate consumer selection)
      selections;
      explicitChoiceRoles = names (consumer.choices or {});
      menuTargets = role:
        if elem role explicitChoiceRoles
        then consumer.choices.${role}
        else
          builtins.filter (targetName: let
            provider = providers.${targets.${targetName}.provider};
            selectedProvider =
              if selections.${role} == null || selections.${role} == ""
              then null
              else targets.${selections.${role}}.provider;
          in
            provider ? endpoint || targets.${targetName}.provider == selectedProvider || (consumer.credentials or {}) ? ${targets.${targetName}.provider}) (names targets);
      choices = builtins.listToAttrs (builtins.map (role: {
          name = role;
          value =
            if selections.${role} == null
            then []
            else builtins.filter (value: value != null) (builtins.map (candidate consumer) (menuTargets role));
        })
        roles);
      errors =
        when (!(all (role: elem role roles) ((names (consumer.roles or {})) ++ explicitChoiceRoles))) "unknown-inference-role" "Consumer ${name} overrides a role not requested by its adapter."
        ++ builtins.concatMap (role:
          when (selections.${role} == "" || (selections.${role} != null && candidates.${role} == null)) "unavailable-inference-role" "Consumer ${name} role ${role} has no admitted target or credential reference."
          ++ (
            if elem role explicitChoiceRoles
            then
              when (
                if selections.${role} == null
                then consumer.choices.${role} != []
                else !(elem selections.${role} consumer.choices.${role}) || builtins.length choices.${role} != builtins.length consumer.choices.${role}
              )
              "invalid-inference-choices" "Consumer ${name} role ${role} has an invalid explicit menu or missing default."
            else []
          ))
        roles;
    in {
      inherit errors;
      value = {
        roles = candidates;
        inherit choices explicitChoiceRoles;
      };
    };
    requestErrors = when (shapesValid && !(all (name: consumers ? ${name}) (names requests))) "unknown-inference-consumer" "Inference requests contain an undeclared consumer.";
    preliminaryErrors = declarationErrors ++ contextErrors ++ requestErrors;
    resolved =
      if preliminaryErrors == []
      then mapAttrs (name: _: resolveConsumer name) requests
      else {};
    diagnostics = preliminaryErrors ++ builtins.concatMap (name: resolved.${name}.errors) (names resolved);
  in {
    valid = diagnostics == [];
    inherit diagnostics;
    consumers =
      if diagnostics == []
      then mapAttrs (_: result: result.value) resolved
      else {};
  };

  checked = result:
    if result.valid
    then result.consumers
    else throw "AI inference configuration is invalid: ${builtins.concatStringsSep "; " (builtins.map (entry: entry.message) result.diagnostics)}";
}
