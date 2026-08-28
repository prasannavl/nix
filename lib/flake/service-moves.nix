{
  lib,
  stacks,
  inventory,
  directory ? null,
  declarations ? null,
}: let
  fail = message: throw "invalid Nix-native service move: ${message}";
  require = condition: message:
    if condition
    then true
    else fail message;
  requireOnly = allowed: value: context: let
    unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames value);
  in
    require (unknown == []) "${context} has unknown fields: ${lib.concatStringsSep ", " unknown}";
  isName = value:
    builtins.isString value
    && builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" value != null;
  isDigest = value:
    builtins.isString value
    && builtins.match "[0-9a-f]{64}" value != null;
  digest = value: builtins.hashString "sha256" (builtins.toJSON value);

  directoryEntries =
    if directory != null && builtins.pathExists directory
    then builtins.readDir directory
    else {};
  declarationFiles = builtins.filter (
    name:
      directoryEntries.${name}
      == "regular"
      && builtins.match ".*\\.nix" name != null
  ) (builtins.attrNames directoryEntries);
  declarationsFromDirectory = builtins.listToAttrs (map (name: {
      name = lib.removeSuffix ".nix" name;
      value = import (directory + "/${name}");
    })
    declarationFiles);
  loadedDeclarations =
    if declarations != null
    then declarations
    else declarationsFromDirectory;

  inventoryResourceId = name: host: host.resourceId or name;
  inventoryHostForResource = resourceId: let
    matches = builtins.filter (
      name: inventoryResourceId name inventory.hosts.${name} == resourceId
    ) (builtins.attrNames inventory.hosts);
  in
    assert require (builtins.length matches == 1) "host resource ${resourceId} does not resolve to exactly one inventory host";
      builtins.head matches;
  roleContext = stack: role: let
    roleSpec = stack.serviceRegistry.roles.${role} or null;
  in
    assert require (roleSpec != null) "stack ${stack.stackName} has no role ${role}"; {
      host = inventoryHostForResource roleSpec.host;
      host_resource = "host:${roleSpec.host}";
    };

  validPhases = [
    "moved"
    "prepared"
    "target-active"
    "rolled-back"
    "adopting-target"
    "adopting-source"
  ];
  selectedRoleFor = move:
    if builtins.elem move.desired.phase ["target-active" "adopting-target"]
    then move.to
    else move.from;
  stableRoleFor = move:
    if move.desired.phase == "adopting-target"
    then move.to
    else move.from;
  projectedPhaseFor = phase:
    {
      moved = "seeded";
      prepared = "prepared";
      "target-active" = "cutover";
      "rolled-back" = "rolled_back";
      "adopting-target" = "cutover";
      "adopting-source" = "rolled_back";
    }
    .${
      phase
    };
  desiredStatesFor = phase:
    {
      moved = {
        source = "active";
        target = "held";
      };
      prepared = {
        source = "held";
        target = "held";
      };
      "target-active" = {
        source = "held";
        target = "active";
      };
      "rolled-back" = {
        source = "active";
        target = "held";
      };
      "adopting-target" = {
        source = "held";
        target = "active";
      };
      "adopting-source" = {
        source = "active";
        target = "held";
      };
    }
    .${
      phase
    };
  activationPurposeFor = phase:
    if builtins.elem phase ["prepared" "target-active" "adopting-target"]
    then "prepared_receipt"
    else if builtins.elem phase ["rolled-back" "adopting-source"]
    then "rollback_receipt"
    else null;

  validateMigration = moveId: service: migration:
    assert require (builtins.isAttrs migration) "move ${moveId} service ${service} has no migration contract";
    assert requireOnly ["kind" "eligibleRoles" "writerResource" "dataRoots" "route"] migration "move ${moveId} service ${service} migration contract";
    assert require (migration.kind == "stateful") "move ${moveId} service ${service} requires a stateful migration contract";
    assert require (builtins.isList migration.eligibleRoles && builtins.length migration.eligibleRoles >= 2) "move ${moveId} service ${service} eligibleRoles must contain at least two roles";
    assert require (lib.all isName migration.eligibleRoles) "move ${moveId} service ${service} eligibleRoles contains an invalid role";
    assert require (builtins.length migration.eligibleRoles == builtins.length (lib.unique migration.eligibleRoles)) "move ${moveId} service ${service} eligibleRoles must be unique";
    assert require (builtins.isString migration.writerResource && builtins.match "service:.+" migration.writerResource != null) "move ${moveId} service ${service} writerResource must be a service resource";
    assert require (builtins.isList migration.dataRoots && migration.dataRoots != []) "move ${moveId} service ${service} dataRoots must not be empty";
    assert require (lib.all (path: builtins.isString path && builtins.match "/.+" path != null) migration.dataRoots) "move ${moveId} service ${service} dataRoots must be absolute strings";
    assert require (builtins.isAttrs migration.route) "move ${moveId} service ${service} route must be an object";
    assert requireOnly ["executorRole" "resource"] migration.route "move ${moveId} service ${service} route";
    assert require (isName migration.route.executorRole) "move ${moveId} service ${service} route executorRole is invalid";
    assert require (builtins.isString migration.route.resource && migration.route.resource != "") "move ${moveId} service ${service} route resource must be non-empty"; migration;

  normalize = fileId: move: let
    context = "move ${fileId}";
    desired = move.desired or {};
    previous = move.previous or {};
    stack = stacks.${move.scope} or null;
    source = roleContext stack move.from;
    target = roleContext stack move.to;
    selectedRole = selectedRoleFor move;
    selected =
      if selectedRole == move.from
      then source
      else target;
    stableRole = stableRoleFor move;
    states = desiredStatesFor desired.phase;
    activationPurpose = activationPurposeFor desired.phase;
    serviceContexts = lib.imap0 (index: service: let
      serviceSpec = stack.serviceRegistry.services.${service} or null;
      migration =
        if serviceSpec == null
        then null
        else validateMigration fileId service (serviceSpec.migration or null);
      routeExecutor = roleContext stack migration.route.executorRole;
      itemId = "item-${lib.fixedWidthNumber 3 (index + 1)}";
      transactionId = "${move.id}--${itemId}";
      sourceHold =
        if desired.leases.source == null
        then null
        else "${itemId}:source-lease-${toString desired.leases.source}";
      targetHold = "${itemId}:target-lease-${toString desired.leases.target}";
      sourceActivation =
        if builtins.elem desired.phase ["rolled-back" "adopting-source"]
        then "${transactionId}-rollback-activate-source-attempt-${toString desired.activationAttempt}"
        else null;
      targetActivation =
        if builtins.elem desired.phase ["target-active" "adopting-target"]
        then "${transactionId}-cutover-activate-target-attempt-${toString desired.activationAttempt}"
        else null;
      sourceProfile = "${service}@${source.host_resource}";
      targetProfile = "${service}@${target.host_resource}";
    in
      assert require (isName service && serviceSpec != null) "${context} service ${service} does not exist in stack ${move.scope}";
      assert require (builtins.elem move.from migration.eligibleRoles && builtins.elem move.to migration.eligibleRoles) "${context} service ${service} endpoints are outside its migration contract";
      assert require (serviceSpec.role == stableRole) "${context} service ${service} stable placement ${serviceSpec.role} does not match required role ${stableRole}"; {
        inherit itemId migration routeExecutor service sourceProfile targetProfile;
        intentItem = {
          kind = "service";
          id = itemId;
          inherit service;
          source_resource = migration.writerResource;
          target_resource = migration.writerResource;
          source.host = source.host;
          target.host = target.host;
          data_roots = [];
        };
        resources = [
          {
            id = "${itemId}:source";
            role = "source";
            kind = "service";
            name = service;
            endpoint = {
              host = source.host;
              host_resource = source.host_resource;
              resource = migration.writerResource;
              hold_epoch = sourceHold;
              transaction_id =
                if sourceHold == null
                then null
                else transactionId;
              activation_job_id = sourceActivation;
              desired_state = states.source;
            };
          }
          {
            id = "${itemId}:target";
            role = "target";
            kind = "service";
            name = service;
            endpoint = {
              host = target.host;
              host_resource = target.host_resource;
              resource = migration.writerResource;
              hold_epoch = targetHold;
              transaction_id = transactionId;
              activation_job_id = targetActivation;
              desired_state = states.target;
            };
          }
        ];
        effects = [
          {
            kind = "service_placement";
            scope = move.scope;
            inherit service;
            host = selected.host;
            host_resource = selected.host_resource;
          }
          {
            kind = "route_profile";
            scope = move.scope;
            inherit service;
            profile =
              if selectedRole == move.from
              then sourceProfile
              else targetProfile;
            baseline_profile = sourceProfile;
            executor_host = routeExecutor.host;
            executor_host_resource = routeExecutor.host_resource;
            executor_resource = migration.route.resource;
            profiles = [
              {
                profile = sourceProfile;
                endpoint_host = source.host;
                endpoint_host_resource = source.host_resource;
                resource = migration.writerResource;
              }
              {
                profile = targetProfile;
                endpoint_host = target.host;
                endpoint_host_resource = target.host_resource;
                resource = migration.writerResource;
              }
            ];
          }
        ];
      })
    move.services;
    intent = {
      schema_version = 1;
      id = move.id;
      declarative_scope = move.scope;
      items = map (service: service.intentItem) serviceContexts;
      consistency_groups = [];
      activation_waves = [];
    };
    intentSha256 = digest intent;
    activationRequirement =
      if activationPurpose == null
      then null
      else {
        kind = activationPurpose;
        requirement_sha256 = digest {
          intent_sha256 = intentSha256;
          purpose = activationPurpose;
          projection_kind = "move";
          schema_version = 1;
          transaction_id = move.id;
        };
      };
    unsignedProjection = {
      schema_version = 1;
      projection_id = move.id;
      intent_kind = "move";
      phase = projectedPhaseFor desired.phase;
      generation = desired.generation;
      inherit intent;
      intent_sha256 = intentSha256;
      resources = builtins.concatMap (service: service.resources) serviceContexts;
      effects = builtins.concatMap (service: service.effects) serviceContexts;
      activation_requirement = activationRequirement;
      previous_projection_sha256 = previous.contract_sha256 or null;
      previous_repository_revision = previous.repository_revision or null;
    };
    projection = unsignedProjection // {projection_sha256 = digest unsignedProjection;};
    affectedHosts = lib.unique ([source.host target.host] ++ map (service: service.routeExecutor.host) serviceContexts);
    writerClaims = lib.unique (builtins.concatMap (service: [
        "${source.host}:${service.migration.writerResource}"
        "${target.host}:${service.migration.writerResource}"
      ])
      serviceContexts);
    dataClaims = lib.unique (builtins.concatMap (service:
      builtins.concatMap (path: ["${source.host}:${path}" "${target.host}:${path}"]) service.migration.dataRoots)
    serviceContexts);
    routeClaims = lib.unique (map (service: "${service.routeExecutor.host}:${service.migration.route.resource}") serviceContexts);
  in
    assert require (builtins.isAttrs move) "${context} must be an object";
    assert requireOnly ["schema_version" "id" "authority" "scope" "services" "from" "to" "desired" "decision" "previous"] move context;
    assert require (move.schema_version == 1) "${context} schema_version must be 1";
    assert require (move.id == fileId && isName move.id) "${context} id must match its filename and contain only safe characters";
    assert require (builtins.elem move.authority ["controller" "local"]) "${context} authority must be controller or local";
    assert require (isName move.scope && stack != null) "${context} scope does not select a stack";
    assert require (builtins.isList move.services && move.services != [] && lib.all isName move.services) "${context} services must be a non-empty name list";
    assert require (builtins.length move.services == builtins.length (lib.unique move.services)) "${context} services must be unique";
    assert require (isName move.from && isName move.to && move.from != move.to) "${context} source and target roles are invalid";
    assert requireOnly ["phase" "generation" "activationAttempt" "leases"] desired "${context} desired";
    assert require (builtins.elem desired.phase validPhases) "${context} phase is unsupported";
    assert require (builtins.isInt desired.generation && desired.generation > 0) "${context} generation must be a positive integer";
    assert require (builtins.isInt desired.activationAttempt && desired.activationAttempt >= 0) "${context} activationAttempt must be a non-negative integer";
    assert require (!builtins.elem desired.phase ["target-active" "rolled-back" "adopting-target" "adopting-source"] || desired.activationAttempt > 0) "${context} active, rollback, and adopting phases require a positive activationAttempt";
    assert requireOnly ["source" "target"] desired.leases "${context} desired leases";
    assert require (desired.leases.source == null || (builtins.isInt desired.leases.source && desired.leases.source > 0)) "${context} source lease must be null or a positive integer";
    assert require (builtins.isInt desired.leases.target && desired.leases.target > 0) "${context} target lease must be a positive integer";
    assert require ((desired.leases.source == null) == (desired.phase == "moved")) "${context} exactly the moved phase leaves the source unleased";
    assert requireOnly ["contract_sha256" "repository_revision"] previous "${context} previous";
    assert require ((previous.contract_sha256 or null) == null || isDigest previous.contract_sha256) "${context} previous contract digest is invalid";
    assert require ((previous.repository_revision or null) == null || (builtins.isString previous.repository_revision && previous.repository_revision != "")) "${context} previous repository revision is invalid";
    assert require (builtins.elem (move.decision or null) [null "complete" "rollback"]) "${context} decision is invalid";
    assert require (((move.decision or null) == "complete") == (desired.phase == "adopting-target")) "${context} complete decision must select adopting-target";
    assert require (((move.decision or null) == "rollback") == (desired.phase == "adopting-source")) "${context} rollback decision must select adopting-source"; {
      declaration = move;
      inherit affectedHosts dataClaims projection routeClaims serviceContexts writerClaims;
      stable_role = stableRole;
      selected_role = selectedRole;
    };

  normalized = builtins.mapAttrs normalize loadedDeclarations;
  serviceClaims = builtins.concatMap (entry: map (service: "${entry.declaration.scope}:${service}") entry.declaration.services) (builtins.attrValues normalized);
  allClaims = claim: builtins.concatMap (entry: entry.${claim}) (builtins.attrValues normalized);
  claimsAreDisjoint = claim: let
    claims = allClaims claim;
  in
    builtins.length claims == builtins.length (lib.unique claims);
  projections = map (entry: entry.projection) (builtins.attrValues normalized);
in {
  entries = assert require (builtins.length serviceClaims == builtins.length (lib.unique serviceClaims)) "active moves overlap one logical service";
  assert require (claimsAreDisjoint "writerClaims") "active moves overlap a writer endpoint";
  assert require (claimsAreDisjoint "dataClaims") "active moves overlap a data root";
  assert require (claimsAreDisjoint "routeClaims") "active moves overlap a route owner"; normalized;
  inherit projections;
  runtimeHosts = lib.unique (builtins.concatMap (entry: entry.affectedHosts) (builtins.attrValues normalized));
  contract = {
    schema_version = 1;
    controller_reconcile_exclusions = map (entry: entry.declaration.id) (builtins.filter (entry: entry.declaration.authority == "local") (builtins.attrValues normalized));
    moves =
      builtins.mapAttrs (_: entry: {
        affected_hosts = entry.affectedHosts;
        inherit (entry) declaration projection selected_role stable_role;
        services =
          map (service: {
            inherit (service) migration service;
          })
          entry.serviceContexts;
      })
      normalized;
  };
}
