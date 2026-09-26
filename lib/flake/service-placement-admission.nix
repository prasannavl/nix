{
  lib,
  baselineStacks,
  effectiveStacks,
  moveContract,
  scopeOwners,
}: let
  validation = import ../validation;
  inherit (validation.mk "invalid service-placement admission") require;
  inherit (import ./service-stack.nix) isServiceStack;

  serviceStacks = lib.filterAttrs (_: isServiceStack) baselineStacks;
  serviceStackScopes = builtins.attrNames serviceStacks;
  familyRolesFor = scope:
    lib.unique (builtins.concatMap (
        familyScope: builtins.attrNames serviceStacks.${familyScope}.serviceRegistry.roles
      )
      (builtins.filter (
          familyScope: scopeOwners.${familyScope} == scopeOwners.${scope}
        )
        serviceStackScopes));
  migrationServicesFor = scope: stack:
    builtins.mapAttrs (service: specification: let
      migration = specification.migration;
      effectiveStack = effectiveStacks.${scope} or null;
      effectiveService =
        if isServiceStack effectiveStack
        then effectiveStack.serviceRegistry.services.${service} or null
        else null;
    in
      assert require (builtins.isAttrs migration) "${scope}:${service} migration must be an object";
      assert require ((migration.kind or null) == "stateful") "${scope}:${service} migration kind must be stateful";
      assert require (builtins.isList (migration.eligibleRoles or null)) "${scope}:${service} migration eligibleRoles must be a list";
      assert require (builtins.length migration.eligibleRoles >= 2) "${scope}:${service} migration must declare at least two eligible roles";
      assert require (builtins.length migration.eligibleRoles == builtins.length (lib.unique migration.eligibleRoles)) "${scope}:${service} migration eligibleRoles must be unique";
      # A family can share one stateful-service contract across stack variants
      # that expose different endpoint groups. Keep its role vocabulary inside
      # that family; concrete placements and moves remain scope-checked below
      # and in service-moves.nix.
      assert require (lib.all (role: builtins.isString role && builtins.elem role (familyRolesFor scope)) migration.eligibleRoles) "${scope}:${service} migration references a role outside its configuration family";
      assert require (effectiveService != null) "${scope}:${service} is absent from the effective service stack";
      assert require (builtins.hasAttr effectiveService.role stack.serviceRegistry.roles) "${scope}:${service} effective role is absent from the baseline service stack";
      assert require (builtins.elem effectiveService.role migration.eligibleRoles) "${scope}:${service} effective role is outside its migration contract"; {
        role = effectiveService.role;
        migration_kind = migration.kind;
      })
    (lib.filterAttrs (_: specification: specification ? migration) stack.serviceRegistry.services);
in {
  schema_version = 3;
  # Keep the deployed schema-3 wire shape stable. Older placement schemas are
  # retired, so predecessor mappings must remain empty.
  predecessors = {
    "1".scope_aliases = {};
    "2".scope_aliases = {};
  };
  placements = builtins.mapAttrs migrationServicesFor serviceStacks;
  moves =
    builtins.mapAttrs (_: move: {
      inherit (move.declaration) decision scope;
      phase = move.declaration.desired.phase;
      basis_sha256 = move.basis_sha256;
      semantic_sha256 = move.semantic_sha256;
      projection_sha256 = move.projection.projection_sha256;
      services = move.services;
      items =
        map (item: {
          inherit (item) basis_sha256 from id service to;
        })
        move.items;
    })
    moveContract.moves;
}
