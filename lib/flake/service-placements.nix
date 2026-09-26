{
  lib,
  stacks,
  document ? null,
}: let
  validation = import ../validation;
  inherit (validation) isName;
  inherit (validation.mk "invalid canonical service placements") require requireOnly;
  inherit (import ./service-stack.nix) applyServiceRoleOverrides isServiceStack;
  loaded =
    if document != null
    then document
    else {
      schema_version = 3;
      placements = {};
    };
  validatePlacement = scope: stack: service: placement: let
    serviceSpec = stack.serviceRegistry.services.${service} or null;
    role = placement.role or null;
    migration =
      if serviceSpec == null
      then null
      else serviceSpec.migration or null;
    validMigration =
      migration
      != null
      && (
        builtins.isAttrs migration
        && (migration.kind or null) == "stateful"
        && builtins.isList (migration.eligibleRoles or null)
        && builtins.length migration.eligibleRoles >= 2
        && builtins.length migration.eligibleRoles == builtins.length (lib.unique migration.eligibleRoles)
        && lib.all (candidate: builtins.isString candidate && builtins.hasAttr candidate stack.serviceRegistry.roles) migration.eligibleRoles
      );
  in
    assert require (builtins.isAttrs placement) "placement ${scope}:${service} must be an object";
    assert requireOnly ["role"] placement "placement ${scope}:${service}";
    assert require (isName service) "placement ${scope}:${service} service must be a safe repository component";
    assert require (serviceSpec != null) "placement ${scope}:${service} does not select a declared service";
    assert require (builtins.isString role && role != "" && builtins.hasAttr role stack.serviceRegistry.roles) "placement ${scope}:${service} role does not select a stack role";
    assert require validMigration "placement ${scope}:${service} has an invalid migration contract";
    assert require (builtins.elem role migration.eligibleRoles) "placement ${scope}:${service} role ${role} is outside its migration contract"; {
      inherit role;
    };
  validateScope = scope: services: let
    stack = stacks.${scope} or null;
  in
    assert require (builtins.isString scope && scope != "") "placement scope must be non-empty";
    assert require (isServiceStack stack) "placement scope ${scope} does not select a service stack";
    assert require (builtins.isAttrs services) "placement scope ${scope} must contain an attribute set";
      builtins.mapAttrs (validatePlacement scope stack) services;
  validatedEnvelope = assert require (builtins.isAttrs loaded) "document must be an object";
  assert require ((loaded.schema_version or null) == 3) "schema_version must be 3";
  assert requireOnly ["schema_version" "placements"] loaded "document";
  assert require (builtins.isAttrs loaded.placements) "placements must be an attribute set"; loaded;
  validated =
    validatedEnvelope
    // {
      placements = builtins.mapAttrs validateScope validatedEnvelope.placements;
    };
  serviceRoleOverridesFor = scope:
    builtins.mapAttrs (_service: placement: placement.role) (validated.placements.${scope} or {});
  applyToStack = scope: stack: let
    overrides = serviceRoleOverridesFor scope;
  in
    applyServiceRoleOverrides stack overrides;
  result = {
    document = validated;
    applyToStacks = candidateStacks:
      assert require (lib.all (scope: builtins.hasAttr scope candidateStacks) (builtins.attrNames validated.placements)) "candidate stacks omit a placement scope";
        builtins.mapAttrs (scope: stack: applyToStack scope stack) candidateStacks;
  };
in
  builtins.deepSeq validated result
