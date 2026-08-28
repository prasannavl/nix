{
  lib,
  file ? null,
  document ? null,
}: let
  fail = message: throw "invalid canonical service placements: ${message}";
  require = condition: message:
    if condition
    then true
    else fail message;
  requireOnly = allowed: value: context: let
    unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames value);
  in
    require (unknown == []) "${context} has unknown fields: ${lib.concatStringsSep ", " unknown}";
  loaded =
    if document != null
    then document
    else if file != null && builtins.pathExists file
    then builtins.fromJSON (builtins.readFile file)
    else {
      schema_version = 1;
      closeouts = {};
      controller_reconcile_exclusions = [];
      placements = {};
    };
  validatePlacement = scope: service: placement:
    assert require (builtins.isAttrs placement) "placement ${scope}:${service} must be an object";
    assert requireOnly ["host" "host_resource" "projection_sha256" "transaction_id"] placement "placement ${scope}:${service}";
    assert require (builtins.isString placement.host && placement.host != "") "placement ${scope}:${service} host must be non-empty";
    assert require (builtins.isString placement.host_resource && builtins.match "host:.+" placement.host_resource != null) "placement ${scope}:${service} host_resource must be canonical";
    assert require (builtins.isString placement.transaction_id && placement.transaction_id != "") "placement ${scope}:${service} transaction_id must be non-empty";
    assert require (builtins.isString placement.projection_sha256 && builtins.match "[0-9a-f]{64}" placement.projection_sha256 != null) "placement ${scope}:${service} projection_sha256 must be lowercase SHA-256"; placement;
  validateScope = scope: services:
    assert require (builtins.isString scope && scope != "") "placement scope must be non-empty";
    assert require (builtins.isAttrs services) "placement scope ${scope} must contain an attribute set";
      builtins.mapAttrs (validatePlacement scope) services;
  validateCloseout = transaction: closeout:
    assert require (builtins.isString transaction && transaction != "") "closeout transaction must be non-empty";
    assert require (builtins.isAttrs closeout) "closeout ${transaction} must be an object";
    assert requireOnly ["affected_hosts" "controller_reconcile" "decision" "projection_sha256"] closeout "closeout ${transaction}";
    assert require (builtins.isList closeout.affected_hosts && closeout.affected_hosts != [] && lib.all (host: builtins.isString host && host != "") closeout.affected_hosts) "closeout ${transaction} affected_hosts must be a non-empty string list";
    assert require (builtins.length closeout.affected_hosts == builtins.length (lib.unique closeout.affected_hosts)) "closeout ${transaction} affected_hosts must be unique";
    assert require (builtins.isBool (closeout.controller_reconcile or true)) "closeout ${transaction} controller_reconcile must be Boolean";
    assert require (builtins.elem closeout.decision ["complete" "rollback"]) "closeout ${transaction} decision is unsupported";
    assert require (builtins.isString closeout.projection_sha256 && builtins.match "[0-9a-f]{64}" closeout.projection_sha256 != null) "closeout ${transaction} projection_sha256 must be lowercase SHA-256";
      closeout // {controller_reconcile = closeout.controller_reconcile or true;};
  validated = assert require (builtins.isAttrs loaded) "document must be an object";
  assert requireOnly ["schema_version" "closeouts" "controller_reconcile_exclusions" "placements"] loaded "document";
  assert require (loaded.schema_version == 1) "schema_version must be 1";
  assert require (builtins.isAttrs loaded.closeouts) "closeouts must be an attribute set";
  assert require (builtins.isList (loaded.controller_reconcile_exclusions or [])) "controller_reconcile_exclusions must be a list";
  assert require (lib.all (projection: builtins.isString projection && projection != "") (loaded.controller_reconcile_exclusions or [])) "controller_reconcile_exclusions must contain non-empty strings";
  assert require (builtins.length (loaded.controller_reconcile_exclusions or []) == builtins.length (lib.unique (loaded.controller_reconcile_exclusions or []))) "controller_reconcile_exclusions must be unique";
  assert require (builtins.isAttrs loaded.placements) "placements must be an attribute set";
    loaded
    // {
      closeouts = builtins.mapAttrs validateCloseout loaded.closeouts;
      controller_reconcile_exclusions = loaded.controller_reconcile_exclusions or [];
      placements = builtins.mapAttrs validateScope loaded.placements;
    };
  roleForHostResource = stack: hostResource: let
    matches =
      builtins.filter
      (role: "host:${stack.serviceRegistry.roles.${role}.host}" == hostResource)
      (builtins.attrNames stack.serviceRegistry.roles);
  in
    if builtins.length matches == 1
    then builtins.head matches
    else fail "host resource ${hostResource} does not select exactly one stack role";
in rec {
  document = validated;

  serviceRoleOverridesFor = scope: stack:
    builtins.mapAttrs
    (_service: placement: roleForHostResource stack placement.host_resource)
    (validated.placements.${scope} or {});

  applyToStack = scope: stack: let
    overrides = serviceRoleOverridesFor scope stack;
    placed = stack.withServiceRoles overrides;
  in
    if overrides == {}
    then stack
    else
      placed
      // lib.optionalAttrs (stack ? placements) {
        placements = builtins.mapAttrs (_: placement: placement.withServiceRoles overrides) stack.placements;
      };

  applyToStacks = stacks:
    builtins.mapAttrs (scope: stack: applyToStack scope stack) stacks;
}
