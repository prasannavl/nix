{
  # Select a surface without losing the provider/account identity used by menus.
  selectNoAuth = api: capability: candidate:
    if
      candidate
      != null
      && candidate.catalogKey != null
      && builtins.elem capability candidate.capabilities
      && candidate.auth
      == {
        kind = "none";
        credentialRef = null;
      }
      && candidate.apis ? ${api}
    then candidate // candidate.apis.${api}
    else null;

  # Choices have already selected the caller's API; keep one connection's menu.
  connectionModels = {
    lib,
    main,
    choices,
    explicit,
  }: let
    identity = route: {inherit (route) provider accountRef auth baseUrl;};
    supported = builtins.filter (route: route != null && identity route == identity main) choices;
    models = builtins.map (route: route.model) supported;
  in
    assert !explicit || builtins.length choices == builtins.length supported;
    assert builtins.any (route: route.target == main.target) supported;
    assert builtins.length models == builtins.length (lib.unique models); models;
}
