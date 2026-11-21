let
  protocols = {
    openai = "openai-compatible";
    ollama = "ollama";
  };
  unique = values: builtins.length values == builtins.length (builtins.attrNames (builtins.groupBy builtins.toJSON values));
  identity = route: {inherit (route) provider accountRef auth baseUrl protocol;};
  check = condition: message:
    if condition
    then true
    else throw message;

  roleSpec = defaultApi: {
    api ? defaultApi,
    capability,
    requiredModel ? null,
    allowRemote ? false,
    transports ? [
      {
        api = api;
        auth = ["none"];
      }
    ],
  }:
    assert check (transports
      != []
      && builtins.all (transport:
        protocols ? ${transport.api}
        && transport.auth != []
        && builtins.all (kind: builtins.elem kind ["none" "bearer"]) transport.auth)
      transports)
    "Inference roles need supported API/auth transports";
    assert check (builtins.elem capability ["chat" "embedding"]) "Inference role capability must be chat or embedding"; {
      inherit capability requiredModel allowRemote transports;
    };

  # Required models constrain selected roles, not alternative menu entries.
  select = spec: candidate:
    if
      candidate
      == null
      || (
        if candidate.catalogKey == null
        then !spec.allowRemote
        else !(builtins.elem spec.capability candidate.capabilities)
      )
    then null
    else let
      supported = builtins.filter (transport:
        candidate.apis ? ${transport.api}
        && builtins.elem candidate.auth.kind transport.auth
        && (
          if candidate.auth.kind == "none"
          then candidate.auth.credentialRef == null
          else candidate.auth.credentialRef != null
        ))
      spec.transports;
    in
      if supported == []
      then null
      else let
        api = (builtins.head supported).api;
      in
        candidate
        // {
          inherit (candidate.apis.${api}) baseUrl model;
          protocol = protocols.${api};
        };

  checkedMenu = name: {
    choices,
    explicit,
    main,
    required,
    sameConnection,
  }: let
    supported = builtins.filter (route: route != null && (!sameConnection || identity route == identity main)) choices;
    contains = selected:
      builtins.any (route:
        route.target == selected.target && identity route == identity selected && route.model == selected.model)
      supported;
  in
    assert check (!explicit || builtins.length choices == builtins.length supported)
    "${name}: explicit menu contains an unsupported connection or model";
    assert check (builtins.all contains required)
    "${name}: menu must include its default and task bindings";
    assert check (unique (builtins.map (route: {
        connection = identity route;
        model = route.model;
      })
      supported))
    "${name}: menu contains duplicate connection/model identities"; supported;

  connections = routes: let
    groups = builtins.groupBy (route: route.provider) routes;
    providers = builtins.foldl' (seen: route:
      if builtins.elem route.provider seen
      then seen
      else seen ++ [route.provider]) []
    routes;
  in
    builtins.map (provider: let
      members = groups.${provider};
      first = builtins.head members;
      models = builtins.map (route: route.model) members;
    in
      assert check (builtins.all (route: identity route == identity first) members && unique models)
      "Inference provider ${provider} has conflicting connections or duplicate models";
        identity first
        // {
          inherit (first) label prefix;
          models = models;
        })
    providers;

  usedCredentialFiles = routes: ownedFiles: let
    refs =
      builtins.groupBy (ref: ref)
      (builtins.filter (ref: ref != null) (builtins.map (route: route.auth.credentialRef) routes));
  in
    assert builtins.all (ref:
      check (ownedFiles ? ${ref}) "Inference credential slot ${ref} is not owned by this service")
    (builtins.attrNames refs);
      builtins.mapAttrs (ref: _: let
        path = ownedFiles.${ref};
      in
        assert check (path == null || (builtins.isString path && builtins.substring 0 1 path == "/"))
        "Inference credential slot ${ref} requires an absolute runtime file path or null"; path)
      refs;
in {
  bind = {
    resolve,
    roleCapabilities ? {},
    catalog ? {},
    presentation ? {},
  }: name: {
    api ? "openai",
    roles,
    menu ? null,
    credentialFiles ? {},
  }: let
    specs = builtins.mapAttrs (role: spec:
      roleSpec api ({
          capability = roleCapabilities.${role} or (throw "${name}.${role}: specify capability for a role without a default");
        }
        // spec))
    roles;
    bindings = resolve name (builtins.attrNames roles);
    selected = builtins.mapAttrs (role: spec: let
      route = select spec bindings.roles.${role};
    in
      assert check (route != null)
      "${name}.${role}: no compatible ${spec.capability} binding for the permitted API/auth transports";
      assert check (spec.requiredModel == null || route.catalogKey == spec.requiredModel)
      "${name}.${role}: selected model does not match its requiredModel (${spec.requiredModel})"; route)
    specs;
    present = route: let
      provider = (presentation.providers or {}).${route.provider} or {};
      prefix = (provider.prefixes or {}).${route.protocol} or route.provider;
      pinned =
        route.catalogKey
        != null
        && (provider.pinCatalog or false)
        && ((catalog.${route.catalogKey} or {}).pinned or false);
    in
      identity route
      // {
        inherit (route) target model capabilities;
        inherit prefix pinned;
        apis = builtins.mapAttrs (_: transport: {inherit (transport) baseUrl model;}) route.apis;
        label = provider.label or "${presentation.labelPrefix or ""}${route.provider}";
        id =
          if prefix == ""
          then route.model
          else "${prefix}.${route.model}";
      };
    menuRoles = builtins.filter (role: specs.${role}.capability == "chat") (builtins.attrNames roles);
    menuRoutes = assert check (builtins.elem menu ["connection" "providers" "namespaced"])
    "${name}: unknown inference menu kind";
    assert check (builtins.elem "main" menuRoles) "${name}: a menu requires a main chat role";
    assert check (builtins.all (role: role == "main") bindings.explicitChoiceRoles)
    "${name}: only the main role exposes a model menu";
      checkedMenu name {
        choices = builtins.map (select specs.main) bindings.choices.main;
        explicit = builtins.elem "main" bindings.explicitChoiceRoles;
        main = selected.main;
        required = builtins.map (role: selected.${role}) menuRoles;
        sameConnection = menu == "connection";
      };
    items = builtins.map present menuRoutes;
    ids = builtins.map (route: route.id) items;
    result =
      {
        roles = builtins.mapAttrs (_: present) selected;
        credentialFiles = usedCredentialFiles (builtins.attrValues selected
          ++ (
            if menu == null
            then []
            else menuRoutes
          ))
        credentialFiles;
      }
      // (
        if menu == null
        then {}
        else {
          menu = assert check (menu != "namespaced" || unique ids) "${name}: ambiguous model namespaces"; {
            ids = ids;
            models = builtins.map (route: route.model) items;
            pinnedModels = builtins.map (route: route.id) (builtins.filter (route: route.pinned) items);
            connections = connections items;
          };
        }
      );
    # Check all bindings and slot ownership, without forcing agenix's module fixed point.
    checks = result // {credentialFiles = builtins.attrNames result.credentialFiles;};
  in
    builtins.deepSeq checks result;
}
