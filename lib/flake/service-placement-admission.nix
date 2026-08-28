{
  lib,
  baselineStacks,
  effectiveStacks,
  moveContract,
}: let
  migrationServicesFor = scope: stack:
    lib.mapAttrs' (service: specification:
      lib.nameValuePair service {
        role = effectiveStacks.${scope}.serviceRegistry.services.${service}.role;
        migration_kind = specification.migration.kind;
      })
    (lib.filterAttrs (_: specification: specification ? migration) stack.serviceRegistry.services);
in {
  schema_version = 1;
  placements = builtins.mapAttrs migrationServicesFor (lib.filterAttrs (_: stack: stack ? serviceRegistry) baselineStacks);
  moves =
    builtins.mapAttrs (_: move: {
      inherit (move.declaration) decision from scope services to;
      phase = move.declaration.desired.phase;
      projection_sha256 = move.projection.projection_sha256;
    })
    moveContract.moves;
}
