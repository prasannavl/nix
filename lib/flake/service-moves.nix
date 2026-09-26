{
  lib,
  stacks,
  inventory,
  placements,
  scopeOwners,
  declarations ? {},
}: let
  validation = import ../validation;
  inherit (validation) isName;
  inherit (validation.mk "invalid Nix-native service move") require requireOnly;
  inherit (import ../validation/paths.nix {inherit lib;}) indexedPairs isCanonicalAbsolutePath pathsOverlap;
  inherit (import ./service-stack.nix) isServiceStack;
  isDigest = value:
    builtins.isString value
    && builtins.match "[0-9a-f]{64}" value != null;
  digest = value: builtins.hashString "sha256" (builtins.toJSON value);
  pad3 = value: let
    rendered = toString value;
  in
    if builtins.stringLength rendered == 1
    then "00${rendered}"
    else if builtins.stringLength rendered == 2
    then "0${rendered}"
    else rendered;

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
  selectedRoleFor = phase: item:
    if builtins.elem phase ["target-active" "adopting-target"]
    then item.to
    else item.from;
  stableRoleFor = phase: item:
    if phase == "adopting-target"
    then item.to
    else item.from;
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
  activationJobId = base: attempt:
    if attempt == 1
    then base
    else "${base}-attempt-${toString (attempt - 1)}";

  validateMigration = moveId: service: migration:
    assert require (builtins.isAttrs migration) "move ${moveId} service ${service} has no migration contract";
    assert requireOnly ["kind" "eligibleRoles" "writerResource" "dataRoots" "route"] migration "move ${moveId} service ${service} migration contract";
    assert require (migration.kind == "stateful") "move ${moveId} service ${service} requires a stateful migration contract";
    assert require (builtins.isList migration.eligibleRoles && builtins.length migration.eligibleRoles >= 2) "move ${moveId} service ${service} eligibleRoles must contain at least two roles";
    assert require (lib.all isName migration.eligibleRoles) "move ${moveId} service ${service} eligibleRoles contains an invalid role";
    assert require (builtins.length migration.eligibleRoles == builtins.length (lib.unique migration.eligibleRoles)) "move ${moveId} service ${service} eligibleRoles must be unique";
    assert require (builtins.isString migration.writerResource && builtins.match "service:.+" migration.writerResource != null) "move ${moveId} service ${service} writerResource must be a service resource";
    assert require (builtins.isList migration.dataRoots && migration.dataRoots != []) "move ${moveId} service ${service} dataRoots must not be empty";
    assert require (lib.all isCanonicalAbsolutePath migration.dataRoots) "move ${moveId} service ${service} dataRoots must be canonical absolute paths";
    assert require (!(builtins.any (pair: pathsOverlap pair.left pair.right) (indexedPairs migration.dataRoots))) "move ${moveId} service ${service} dataRoots overlap";
    assert require (builtins.isAttrs migration.route) "move ${moveId} service ${service} route must be an object";
    assert requireOnly ["executorRole" "resource"] migration.route "move ${moveId} service ${service} route";
    assert require (isName migration.route.executorRole) "move ${moveId} service ${service} route executorRole is invalid";
    assert require (builtins.isString migration.route.resource && migration.route.resource != "") "move ${moveId} service ${service} route resource must be non-empty"; migration;

  basisFor = scope: stack: service: from: to: let
    serviceSpec = stack.serviceRegistry.services.${service} or null;
    migration =
      if serviceSpec == null
      then null
      else validateMigration "basis:${scope}" service (serviceSpec.migration or null);
    source = roleContext stack from;
    target = roleContext stack to;
    routeExecutor = roleContext stack migration.route.executorRole;
    basis = {
      schema_version = 1;
      inherit from scope service to;
      service_contract = builtins.removeAttrs serviceSpec ["role"];
      topology = {
        source = source // {role = from;};
        target = target // {role = to;};
        route_executor = routeExecutor // {role = migration.route.executorRole;};
      };
    };
  in {
    inherit basis;
    basis_sha256 = digest basis;
  };

  normalizeItem = fileId: move: desired: index: item: let
    context = "move ${fileId} item ${item.id or "<unknown>"}";
    expectedId = "item-${pad3 (index + 1)}";
    stack = stacks.${move.scope};
    service = item.service or null;
    serviceSpec = stack.serviceRegistry.services.${service} or null;
    migration =
      if serviceSpec == null
      then null
      else validateMigration fileId service (serviceSpec.migration or null);
    source = roleContext stack item.from;
    target = roleContext stack item.to;
    routeExecutor = roleContext stack migration.route.executorRole;
    selectedRole = selectedRoleFor desired.phase item;
    selected =
      if selectedRole == item.from
      then source
      else target;
    stableRole = stableRoleFor desired.phase item;
    serviceBasis = basisFor move.scope stack service item.from item.to;
    lease = desired.leases.${item.id} or {};
    sourceLease = lease.source or null;
    targetLease = lease.target or null;
    sourceHold =
      if sourceLease == null
      then null
      else "${item.id}:source-lease-${toString sourceLease}";
    targetHold =
      if targetLease == null
      then null
      else "${item.id}:target-lease-${toString targetLease}";
    transactionId = "${move.id}--${item.id}";
    activationAttempts = desired.activationAttempts.${item.id};
    sourceActivation =
      if builtins.elem desired.phase ["rolled-back" "adopting-source"]
      then activationJobId "${transactionId}-rollback-activate-source" activationAttempts.source
      else null;
    targetActivation =
      if builtins.elem desired.phase ["target-active" "adopting-target"]
      then activationJobId "${transactionId}-cutover-activate-target" activationAttempts.target
      else null;
    sourceProfile = "${service}@${source.host_resource}";
    targetProfile = "${service}@${target.host_resource}";
    generatedIds = builtins.filter (value: value != null) [
      transactionId
      sourceActivation
      targetActivation
    ];
    states = desiredStatesFor desired.phase;
    intentItem = {
      kind = "service";
      id = item.id;
      inherit service;
      source_resource = migration.writerResource;
      target_resource = migration.writerResource;
      source.host = source.host;
      target.host = target.host;
      data_roots = [];
    };
    resources = [
      {
        id = "${item.id}:source";
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
        id = "${item.id}:target";
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
          if selectedRole == item.from
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
    writerClaims = [
      {
        host = source.host;
        resource = migration.writerResource;
      }
      {
        host = target.host;
        resource = migration.writerResource;
      }
    ];
    dataClaims =
      builtins.concatMap (path: [
        {
          host = source.host;
          inherit path;
        }
        {
          host = target.host;
          inherit path;
        }
      ])
      migration.dataRoots;
    routeClaims = [
      {
        host = routeExecutor.host;
        resource = migration.route.resource;
      }
    ];
    claims =
      [
        {
          namespace = "service";
          key = "${move.scope}/${service}";
          overlap = "exact";
        }
      ]
      ++ map (claim: {
        namespace = "host-resource";
        key = "${claim.host}/${claim.resource}";
        overlap = "exact";
      }) (writerClaims ++ routeClaims)
      ++ map (claim: {
        namespace = "host-path";
        key = "${claim.host}${claim.path}";
        overlap = "path-prefix";
      })
      dataClaims;
  in
    assert require (builtins.isAttrs item) "${context} must be an object";
    assert requireOnly ["id" "service" "from" "to" "basis_sha256"] item context;
    assert require (item.id == expectedId) "${context} id must be canonical ${expectedId}";
    assert require (isName service && serviceSpec != null) "${context} service does not exist in stack ${move.scope}";
    assert require (isName item.from && isName item.to && item.from != item.to) "${context} source and target roles are invalid";
    assert require (builtins.elem item.from migration.eligibleRoles && builtins.elem item.to migration.eligibleRoles) "${context} endpoints are outside the service migration contract";
    assert require (isDigest item.basis_sha256 && item.basis_sha256 == serviceBasis.basis_sha256) "${context} service capsule or endpoint topology drifted from basis_sha256";
    assert require (serviceSpec.role == stableRole) "${context} stable placement ${serviceSpec.role} does not match required role ${stableRole}";
    assert requireOnly ["source" "target"] lease "${context} lease";
    assert require (sourceLease == null || (builtins.isInt sourceLease && sourceLease > 0)) "${context} source lease must be null or a positive integer";
    assert require (builtins.isInt targetLease && targetLease > 0) "${context} target lease must be a positive integer";
    assert require ((sourceLease == null) == (desired.phase == "moved")) "${context} exactly the moved phase leaves the source unleased";
    assert require (lib.all (value: builtins.stringLength value <= 128) generatedIds) "${context} produces a runtime identity longer than 128 characters"; {
      declaration = item;
      inherit
        claims
        dataClaims
        effects
        intentItem
        migration
        resources
        routeClaims
        routeExecutor
        service
        source
        stableRole
        target
        writerClaims
        ;
      affectedHosts = lib.unique [source.host target.host routeExecutor.host];
      basis = serviceBasis.basis;
      basis_sha256 = serviceBasis.basis_sha256;
      selected_role = selectedRole;
      stable_role = stableRole;
    };

  normalize = fileId: move: let
    context = "move ${fileId}";
    desired = move.desired or {};
    previous = move.previous or {};
    stack = stacks.${move.scope or ""} or null;
    items = move.items or [];
    requiredItemFields = ["id" "service" "from" "to" "basis_sha256"];
    validItemEnvelope = item:
      builtins.isAttrs item
      && lib.all (field: builtins.hasAttr field item) requiredItemFields;
    rawItemIds = map (item: item.id or null) items;
    rawServices = map (item: item.service or null) items;
    desiredPhase = desired.phase or null;
    desiredGeneration = desired.generation or null;
    activationAttempts = desired.activationAttempts or {};
    leases = desired.leases or null;
    normalizedDesired =
      desired
      // {
        phase = desiredPhase;
        generation = desiredGeneration;
        inherit activationAttempts leases;
      };
    normalizedItems = lib.imap0 (normalizeItem fileId move normalizedDesired) items;
    itemIds = rawItemIds;
    services = rawServices;
    leaseIds =
      if builtins.isAttrs leases
      then builtins.attrNames leases
      else [];
    activationPurpose = activationPurposeFor desiredPhase;
    semantic = {
      schema_version = 2;
      inherit (move) authority id scope;
      items = map (item: item.declaration) normalizedItems;
    };
    semanticSha256 = digest semantic;
    intent = {
      schema_version = 1;
      id = move.id;
      declarative_scope = move.scope;
      repository_owner = scopeOwners.${move.scope};
      items = map (item: item.intentItem) normalizedItems;
      consistency_groups = [];
      activation_waves = [];
    };
    intentSha256 = digest intent;
    previousActivationRequirement = previous.activation_requirement or null;
    inheritsActivationRequirement =
      builtins.elem desiredPhase ["target-active" "adopting-target"]
      || (
        builtins.elem desiredPhase ["rolled-back" "adopting-source"]
        && previousActivationRequirement != null
        && (previousActivationRequirement.kind or null) == activationPurpose
      );
    activationRequirement =
      if activationPurpose == null
      then null
      else if inheritsActivationRequirement
      then previousActivationRequirement
      else {
        kind = activationPurpose;
        requirement_sha256 = digest {
          generation = desiredGeneration;
          intent_sha256 = intentSha256;
          previous_projection_sha256 = previous.contract_sha256 or null;
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
      phase = projectedPhaseFor desiredPhase;
      generation = desiredGeneration;
      inherit intent;
      intent_sha256 = intentSha256;
      resources = builtins.concatMap (item: item.resources) normalizedItems;
      effects = builtins.concatMap (item: item.effects) normalizedItems;
      activation_requirement = activationRequirement;
      previous_projection_sha256 = previous.contract_sha256 or null;
      previous_repository_revision = previous.repository_revision or null;
    };
    projection = unsignedProjection // {projection_sha256 = digest unsignedProjection;};
    transactionBasis =
      map (item: {
        id = item.declaration.id;
        basis_sha256 = item.basis_sha256;
      })
      normalizedItems;
  in
    assert require (builtins.isAttrs move) "${context} must be an object";
    assert requireOnly ["schema_version" "id" "authority" "scope" "items" "desired" "decision" "previous"] move context;
    assert require (move.schema_version == 4) "${context} schema_version must be 4";
    assert require (move.id == fileId && isName move.id) "${context} id must match its filename and contain only safe characters";
    assert require (builtins.elem move.authority ["controller" "local"]) "${context} authority must be controller or local";
    assert require (isName move.scope && stack != null) "${context} scope does not select a stack";
    assert require (isServiceStack stack) "${context} scope does not select a service stack";
    assert require (builtins.isList items && items != []) "${context} items must be a non-empty list";
    assert require (builtins.length items <= 999) "${context} may contain at most 999 services";
    assert require (lib.all validItemEnvelope items) "${context} items must be objects with id, service, from, to, and basis_sha256";
    assert require (lib.all isName rawItemIds) "${context} item ids must be safe repository components";
    assert require (builtins.length services == builtins.length (lib.unique services)) "${context} contains a duplicate service";
    assert require (builtins.isAttrs desired) "${context} desired must be an object";
    assert requireOnly ["phase" "generation" "activationAttempts" "leases"] desired "${context} desired";
    assert require (builtins.elem desiredPhase validPhases) "${context} phase is unsupported";
    assert require (builtins.isInt desiredGeneration && desiredGeneration > 0) "${context} generation must be a positive integer";
    assert require (builtins.isAttrs activationAttempts && lib.sort builtins.lessThan (builtins.attrNames activationAttempts) == lib.sort builtins.lessThan rawItemIds) "${context} activation attempts must cover every item exactly";
    assert require (lib.all (
      attempts:
        builtins.isAttrs attempts
        && requireOnly ["source" "target"] attempts "${context} activation attempt"
        && lib.all (attempt: builtins.isInt attempt && attempt > 0 && attempt <= 999999999) [(attempts.source or null) (attempts.target or null)]
    ) (builtins.attrValues activationAttempts)) "${context} activation attempts must be positive bounded integers";
    assert require (builtins.isAttrs leases && lib.sort builtins.lessThan leaseIds == lib.sort builtins.lessThan itemIds) "${context} leases must cover every item exactly";
    assert require (lib.all (
      lease:
        builtins.isAttrs lease
        && requireOnly ["source" "target"] lease "${context} lease"
    ) (builtins.attrValues leases)) "${context} leases must be objects";
    assert require (builtins.isAttrs previous) "${context} previous must be an object";
    assert requireOnly ["activation_requirement" "contract_sha256" "repository_revision"] previous "${context} previous";
    assert require ((previous.contract_sha256 or null) == null || isDigest previous.contract_sha256) "${context} previous contract digest is invalid";
    assert require ((previous.repository_revision or null) == null || (builtins.isString previous.repository_revision && previous.repository_revision != "")) "${context} previous repository revision is invalid";
    assert require (
      previousActivationRequirement
      == null
      || (
        builtins.isAttrs previousActivationRequirement
        && requireOnly ["kind" "requirement_sha256"] previousActivationRequirement "${context} previous activation requirement"
        && builtins.elem (previousActivationRequirement.kind or null) ["prepared_receipt" "rollback_receipt"]
        && isDigest (previousActivationRequirement.requirement_sha256 or null)
      )
    ) "${context} previous activation requirement is invalid";
    assert require (
      !builtins.elem desiredPhase ["target-active" "adopting-target"]
      || (previousActivationRequirement != null && previousActivationRequirement.kind == "prepared_receipt")
    ) "${context} target activation must inherit the exact prepared requirement";
    assert require (builtins.elem (move.decision or null) [null "complete" "rollback"]) "${context} decision is invalid";
    assert require (((move.decision or null) == "complete") == (desiredPhase == "adopting-target")) "${context} complete decision must select adopting-target";
    assert require (((move.decision or null) == "rollback") == (desiredPhase == "adopting-source")) "${context} rollback decision must select adopting-source"; {
      declaration = move;
      inherit projection semantic;
      affectedHosts = lib.unique (builtins.concatMap (item: item.affectedHosts) normalizedItems);
      basis_sha256 = digest transactionBasis;
      claims = builtins.concatMap (item: item.claims) normalizedItems;
      dataClaims = builtins.concatMap (item: item.dataClaims) normalizedItems;
      items = normalizedItems;
      routeClaims = builtins.concatMap (item: item.routeClaims) normalizedItems;
      semanticSha256 = semanticSha256;
      writerClaims = builtins.concatMap (item: item.writerClaims) normalizedItems;
    };

  normalized = builtins.mapAttrs normalize declarations;
  ownedClaims = claim:
    builtins.concatLists (lib.mapAttrsToList (transaction: entry:
      map (value: value // {inherit transaction;}) entry.${claim})
    normalized);
  serviceClaims = builtins.concatLists (lib.mapAttrsToList (transaction: entry:
    map (item: {
      inherit transaction;
      scope = entry.declaration.scope;
      service = item.service;
    })
    entry.items)
  normalized);
  serviceConflict = pair:
    pair.left.scope
    == pair.right.scope
    && pair.left.service == pair.right.service;
  resourceConflict = pair:
    pair.left.host
    == pair.right.host
    && pair.left.resource == pair.right.resource;
  interTransactionResourceConflict = pair:
    pair.left.transaction
    != pair.right.transaction
    && resourceConflict pair;
  dataConflict = pair:
    pair.left.host
    == pair.right.host
    && pathsOverlap pair.left.path pair.right.path;
  hasConflict = predicate: claims:
    builtins.any predicate (indexedPairs claims);
  crossPairs = left: right:
    builtins.concatMap
    (leftClaim:
      map (rightClaim: {
        left = leftClaim;
        right = rightClaim;
      })
      right)
    left;
  writerClaims = ownedClaims "writerClaims";
  dataClaims = ownedClaims "dataClaims";
  routeClaims = ownedClaims "routeClaims";
  validatedEntries = assert require (!(hasConflict serviceConflict serviceClaims)) "active moves overlap one logical service";
  assert require (!(hasConflict resourceConflict writerClaims)) "active moves overlap a writer resource";
  assert require (!(lib.any resourceConflict (crossPairs writerClaims routeClaims))) "active moves overlap a writer and route resource";
  assert require (!(hasConflict interTransactionResourceConflict routeClaims)) "active moves overlap a route resource across transactions";
  assert require (!(hasConflict dataConflict dataClaims)) "active moves overlap a data root"; normalized;
  projections = map (entry: entry.projection) (builtins.attrValues validatedEntries);
  movableSpecifications = scope: stack:
    builtins.mapAttrs (service: _placement: let
      specification = stack.serviceRegistry.services.${service} or null;
      migration =
        if specification == null
        then null
        else validateMigration "basis:${scope}" service (specification.migration or null);
    in
      assert require (specification != null) "basis:${scope} service ${service} does not exist";
      assert require (lib.all (role: builtins.hasAttr role stack.serviceRegistry.roles) migration.eligibleRoles) "basis:${scope} service ${service} references a role outside the scope"; specification)
    (placements.${scope} or {});
  basisCatalog = builtins.mapAttrs (scope: stack:
    builtins.mapAttrs (service: specification: let
      migration = validateMigration "basis:${scope}" service specification.migration;
    in
      builtins.listToAttrs (map (from: {
          name = from;
          value = builtins.listToAttrs (map (to: {
              name = to;
              value = (basisFor scope stack service from to).basis_sha256;
            })
            (builtins.filter (to: to != from) migration.eligibleRoles));
        })
        migration.eligibleRoles))
    (movableSpecifications scope stack))
  (lib.filterAttrs (_: isServiceStack) stacks);
  contract = {
    schema_version = 2;
    basis_catalog = basisCatalog;
    controller_reconcile_exclusions = map (entry: entry.declaration.id) (builtins.filter (entry: entry.declaration.authority == "local") (builtins.attrValues validatedEntries));
    moves =
      builtins.mapAttrs (_: entry: {
        affected_hosts = entry.affectedHosts;
        inherit (entry) basis_sha256 declaration projection;
        semantic_sha256 = entry.semanticSha256;
        items =
          map (item: {
            inherit (item) basis_sha256 migration service selected_role stable_role;
            inherit (item.declaration) from id to;
          })
          entry.items;
        services = map (item: item.service) entry.items;
      })
      validatedEntries;
  };
  result = {
    entries = validatedEntries;
    inherit contract projections;
    runtimeHosts = lib.unique (builtins.concatMap (entry: entry.affectedHosts) (builtins.attrValues validatedEntries));
  };
in
  builtins.deepSeq {
    inherit basisCatalog validatedEntries;
  }
  result
