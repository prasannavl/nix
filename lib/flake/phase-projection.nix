{
  lib,
  directory ? null,
  documents ? null,
}: let
  fail = message: throw "invalid phase projection: ${message}";
  require = condition: message:
    if condition
    then true
    else fail message;
  requireOnly = allowed: value: context: let
    unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames value);
  in
    require (unknown == []) "${context} has unknown fields: ${lib.concatStringsSep ", " unknown}";
  isDigest = value:
    builtins.isString value
    && builtins.match "[0-9a-f]{64}" value != null;
  containsFloat = value:
    builtins.isFloat value
    || (builtins.isList value && lib.any containsFloat value)
    || (builtins.isAttrs value && lib.any containsFloat (builtins.attrValues value));
  directoryEntries =
    if directory != null && builtins.pathExists directory
    then builtins.readDir directory
    else {};
  projectionFiles =
    builtins.filter
    (name:
      directoryEntries.${name}
      == "regular"
      && builtins.match ".*\\.json" name != null)
    (builtins.attrNames directoryEntries);
  loadedDocuments =
    if documents != null
    then documents
    else
      map
      (name: builtins.fromJSON (builtins.readFile (directory + "/${name}")))
      projectionFiles;

  validateEndpoint = endpoint:
    assert require (builtins.isAttrs endpoint) "resource endpoint must be an object";
    assert requireOnly ["host" "host_resource" "resource" "hold_epoch" "transaction_id" "activation_job_id" "desired_state"] endpoint "resource endpoint";
    assert require (builtins.isString endpoint.host && endpoint.host != "") "endpoint host must be non-empty";
    assert require (builtins.isString endpoint.host_resource && builtins.match "host:.+" endpoint.host_resource != null) "endpoint host_resource must be canonical";
    assert require (builtins.isString endpoint.resource && endpoint.resource != "") "endpoint resource must be non-empty";
    assert require (builtins.elem endpoint.desired_state ["held" "active" "inactive" "unheld"]) "endpoint desired_state is unsupported";
    assert require (endpoint.hold_epoch == null || (builtins.isString endpoint.hold_epoch && endpoint.hold_epoch != "")) "endpoint hold_epoch must be null or non-empty";
    assert require (endpoint.transaction_id == null || (builtins.isString endpoint.transaction_id && endpoint.transaction_id != "")) "endpoint transaction_id must be null or non-empty";
    assert require ((endpoint.hold_epoch == null) == (endpoint.transaction_id == null)) "endpoint hold_epoch and transaction_id must be declared together";
    assert require (endpoint.activation_job_id == null || (builtins.isString endpoint.activation_job_id && endpoint.activation_job_id != "")) "endpoint activation_job_id must be null or non-empty";
    assert require ((endpoint.desired_state == "active" && endpoint.hold_epoch != null) == (endpoint.activation_job_id != null)) "exactly active held endpoints require activation_job_id";
    assert require (endpoint.desired_state == "active" || endpoint.hold_epoch != null) "held, inactive, and unheld endpoints require a hold_epoch"; endpoint;

  validateResource = resource:
    assert require (builtins.isAttrs resource) "resources must contain objects";
    assert requireOnly ["id" "role" "kind" "name" "endpoint"] resource "resource";
    assert require (builtins.isString resource.id && resource.id != "") "resource id must be non-empty";
    assert require (builtins.isString resource.role && resource.role != "") "resource role must be non-empty";
    assert require (builtins.elem resource.kind ["host" "service" "resource" "instance"]) "resource kind is unsupported";
    assert require (builtins.isString resource.name && resource.name != "") "resource name must be non-empty";
      resource
      // {endpoint = validateEndpoint resource.endpoint;};

  validateRouteProfile = profile:
    assert require (builtins.isAttrs profile) "route profiles must contain objects";
    assert requireOnly ["profile" "endpoint_host" "endpoint_host_resource" "resource"] profile "allowed route profile";
    assert require (builtins.isString profile.profile && profile.profile != "") "allowed route profile name must be non-empty";
    assert require (builtins.isString profile.endpoint_host && profile.endpoint_host != "") "allowed route profile endpoint host must be non-empty";
    assert require (builtins.isString profile.endpoint_host_resource && builtins.match "host:.+" profile.endpoint_host_resource != null) "allowed route profile endpoint_host_resource must be canonical";
    assert require (builtins.isString profile.resource && profile.resource != "") "allowed route profile resource must be non-empty"; profile;

  validateEffect = effect:
    assert require (builtins.isAttrs effect) "effects must contain objects";
    assert require (builtins.isString effect.kind && effect.kind != "") "effect kind must be non-empty";
      if effect.kind == "service_placement"
      then
        assert requireOnly ["kind" "scope" "service" "host" "host_resource"] effect "service placement effect";
        assert require (builtins.isString effect.scope && effect.scope != "") "service placement scope must be non-empty";
        assert require (builtins.isString effect.service && effect.service != "") "service placement service must be non-empty";
        assert require (builtins.isString effect.host && effect.host != "") "service placement host must be non-empty";
        assert require (builtins.isString effect.host_resource && builtins.match "host:.+" effect.host_resource != null) "service placement host_resource must be canonical"; effect
      else if effect.kind == "route_profile"
      then
        assert requireOnly ["kind" "scope" "service" "profile" "baseline_profile" "executor_host" "executor_host_resource" "executor_resource" "profiles"] effect "route profile effect";
        assert require (builtins.isString effect.scope && effect.scope != "") "route profile scope must be non-empty";
        assert require (builtins.isString effect.service && effect.service != "") "route profile service must be non-empty";
        assert require (builtins.isString effect.profile && effect.profile != "") "route profile name must be non-empty";
        assert require (builtins.isString effect.baseline_profile && effect.baseline_profile != "") "route baseline profile must be non-empty";
        assert require (builtins.isString effect.executor_host && effect.executor_host != "") "route profile executor host must be non-empty";
        assert require (builtins.isString effect.executor_host_resource && builtins.match "host:.+" effect.executor_host_resource != null) "route profile executor host_resource must be canonical";
        assert require (builtins.isString effect.executor_resource && effect.executor_resource != "") "route profile executor resource must be non-empty";
        assert require (builtins.isList effect.profiles && effect.profiles != []) "route profile effect must declare allowed profiles";
          effect
          // {profiles = map validateRouteProfile effect.profiles;}
      else fail "unsupported effect kind ${effect.kind}";

  validateActivation = activation:
    if activation == null
    then null
    else
      assert require (builtins.isAttrs activation) "activation_requirement must be null or an object";
      assert requireOnly ["kind" "requirement_sha256"] activation "activation requirement";
      assert require (builtins.isString activation.kind && activation.kind != "") "activation requirement kind must be non-empty";
      assert require (isDigest activation.requirement_sha256) "activation requirement digest must be lowercase SHA-256"; activation;

  validateDocument = projection:
    assert require (builtins.isAttrs projection) "document must be an object";
    assert requireOnly ["schema_version" "projection_id" "intent_kind" "phase" "generation" "intent" "intent_sha256" "resources" "effects" "activation_requirement" "previous_projection_sha256" "previous_repository_revision" "projection_sha256"] projection "projection document";
    assert require (projection.schema_version == 1) "schema_version must be 1";
    assert require (builtins.isString projection.projection_id && builtins.stringLength projection.projection_id <= 128 && builtins.match "[A-Za-z0-9_-]+" projection.projection_id != null) "projection_id must be 1..128 ASCII alphanumeric, hyphen, or underscore characters";
    assert require (builtins.isString projection.intent_kind && projection.intent_kind != "") "intent_kind must be non-empty";
    assert require (builtins.isString projection.phase && projection.phase != "") "phase must be non-empty";
    assert require (builtins.isInt projection.generation && projection.generation > 0) "generation must be positive";
    assert require (isDigest projection.intent_sha256) "intent_sha256 must be lowercase SHA-256";
    assert require (isDigest projection.projection_sha256) "projection_sha256 must be lowercase SHA-256";
    assert require (projection.previous_projection_sha256 == null || isDigest projection.previous_projection_sha256) "previous projection digest must be null or lowercase SHA-256";
    assert require (projection.previous_repository_revision == null || (builtins.isString projection.previous_repository_revision && projection.previous_repository_revision != "")) "previous repository revision must be null or non-empty";
    assert require (builtins.isList projection.resources) "resources must be a list";
    assert require (builtins.isList projection.effects) "effects must be a list";
    assert require (!containsFloat projection.intent) "floating-point intent values are not canonical"; let
      validated =
        projection
        // {
          resources = map validateResource projection.resources;
          effects = map validateEffect projection.effects;
          activation_requirement = validateActivation projection.activation_requirement;
        };
      unsigned = builtins.removeAttrs validated ["projection_sha256"];
      expectedDigest = builtins.hashString "sha256" (builtins.toJSON unsigned);
      serviceEndpointsFor = service:
        builtins.filter
        (resource: resource.kind == "service" && resource.name == service)
        validated.resources;
      matchingEndpoint = service: profile:
        builtins.filter
        (resource:
          resource.endpoint.host
          == profile.endpoint_host
          && resource.endpoint.host_resource == profile.endpoint_host_resource
          && resource.endpoint.resource == profile.resource)
        (serviceEndpointsFor service);
      placements = builtins.filter (effect: effect.kind == "service_placement") validated.effects;
      routes = builtins.filter (effect: effect.kind == "route_profile") validated.effects;
      endpointKeys = map (resource: "${resource.endpoint.host}:${resource.endpoint.resource}") validated.resources;
      placementKeys = map (effect: "${effect.scope}:${effect.service}") placements;
      routeKeys = map (effect: "${effect.scope}:${effect.service}") routes;
      matchingPlacement = route: let
        selected = lib.findFirst (profile: profile.profile == route.profile) null route.profiles;
      in
        builtins.filter
        (placement:
          placement.scope
          == route.scope
          && placement.service == route.service
          && selected != null
          && placement.host == selected.endpoint_host
          && placement.host_resource == selected.endpoint_host_resource)
        placements;
    in
      assert require (builtins.hashString "sha256" (builtins.toJSON projection.intent) == projection.intent_sha256) "intent_sha256 does not match intent";
      assert require (expectedDigest == projection.projection_sha256) "projection_sha256 does not match canonical content";
      assert require (lib.length endpointKeys == lib.length (lib.unique endpointKeys)) "host and resource endpoints must be unique within a projection";
      assert require (lib.all (resource:
        resource.endpoint.desired_state
        != "active"
        || resource.endpoint.hold_epoch == null
        || validated.activation_requirement != null)
      validated.resources) "activating a projected hold requires an activation requirement";
      assert require (lib.length placementKeys == lib.length (lib.unique placementKeys)) "service placement effects must be unique by scope and service";
      assert require (lib.length routeKeys == lib.length (lib.unique routeKeys)) "route profile effects must be unique by scope and service";
      assert require (lib.all (effect:
        lib.length (builtins.filter
          (resource:
            resource.endpoint.host
            == effect.host
            && resource.endpoint.host_resource == effect.host_resource)
          (serviceEndpointsFor effect.service))
        == 1)
      placements) "service placement must select exactly one projected service endpoint";
      assert require (lib.all (route: let
        names = map (profile: profile.profile) route.profiles;
      in
        lib.length names
        == lib.length (lib.unique names)
        && builtins.elem route.profile names
        && builtins.elem route.baseline_profile names
        && lib.all (profile: lib.length (matchingEndpoint route.service profile) == 1) route.profiles)
      routes) "route profiles must be unique, contain the selected and baseline profiles, and each select one projected service endpoint";
      assert require (lib.all (route: lib.length (matchingPlacement route) == 1) routes) "route profile endpoint must match projected placement"; validated;

  validatedDocuments = map validateDocument loadedDocuments;
  projectionIds = map (projection: projection.projection_id) validatedDocuments;
  resourceIds = projection:
    map (resource: resource.id) projection.resources;

  roleForHostResource = stack: hostResource: let
    matches =
      builtins.filter
      (role: "host:${stack.serviceRegistry.roles.${role}.host}" == hostResource)
      (builtins.attrNames stack.serviceRegistry.roles);
  in
    if builtins.length matches == 1
    then builtins.head matches
    else fail "host resource ${hostResource} does not select exactly one stack role";

  placementEffectsFor = scope:
    builtins.concatMap
    (projection:
      builtins.filter
      (effect: effect.kind == "service_placement" && effect.scope == scope)
      projection.effects)
    validatedDocuments;
in rec {
  documents = assert require (lib.length projectionIds == lib.length (lib.unique projectionIds)) "projection_id values must be unique";
  assert require (lib.all (projection: lib.length (resourceIds projection) == lib.length (lib.unique (resourceIds projection))) validatedDocuments) "resource IDs must be unique within a projection"; validatedDocuments;

  serviceRoleOverridesFor = scope: stack:
    builtins.foldl'
    (overrides: effect: let
      role = roleForHostResource stack effect.host_resource;
    in
      if builtins.hasAttr effect.service overrides
      then
        if overrides.${effect.service} == role
        then overrides
        else fail "service ${effect.service} has conflicting projected placements"
      else overrides // {${effect.service} = role;})
    {}
    (placementEffectsFor scope);

  applyToStack = scope: stack: let
    overrides = serviceRoleOverridesFor scope stack;
    projected = stack.withServiceRoles overrides;
  in
    if overrides == {}
    then stack
    else
      projected
      // lib.optionalAttrs (stack ? placements) {
        placements = builtins.mapAttrs (_: placement: placement.withServiceRoles overrides) stack.placements;
      };

  applyToStacks = stacks:
    builtins.mapAttrs (scope: stack: applyToStack scope stack) stacks;
}
