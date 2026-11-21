{
  admission,
  moves,
  placements,
}: {
  lib,
  repositoryLayout,
}: {
  servicePlacements = {
    schema_version = 1;
    dependencies = [];
    evaluate = state: let
      baselineStacks = state.context.baselineStacks;
      placement = placements {
        inherit lib;
        stacks = baselineStacks;
        document = state.fragment;
      };
      canonicalStacks = placement.applyToStacks baselineStacks;
      placementPaths = builtins.concatLists (lib.mapAttrsToList (scope: services:
        map (service: repositoryLayout.placementPathFor scope service) (builtins.attrNames services))
      placement.document.placements);
    in {
      schema_version = 1;
      contract = placement.document;
      generation = {stack_overrides = placement.document.placements;};
      runtime = {plans = [];};
      admission = {enabled = false;};
      claims = [];
      repository = {
        document_kind = "service-placement";
        owned_paths = placementPaths;
      };
      next_context = {inherit canonicalStacks;};
    };
  };

  serviceMoves = {
    schema_version = 1;
    dependencies = ["servicePlacements"];
    evaluate = state: let
      canonicalStacks = state.context.canonicalStacks;
      contextScopeOwners = state.context.scopeOwners;
      resolvedMoves = moves {
        inherit lib;
        inventory = state.context.inventory;
        scopeOwners = contextScopeOwners;
        stacks = canonicalStacks;
        placements = state.domains.servicePlacements.contract.placements;
        declarations = state.fragment;
      };
      moveClaims = builtins.concatMap (entry:
        map (claim: {
          access = "exclusive";
          inherit (claim) key namespace overlap;
          owner = entry.declaration.id;
        })
        entry.claims)
      (builtins.attrValues resolvedMoves.entries);
      movePaths = map (
        entry: repositoryLayout.movePathFor entry.declaration.scope entry.declaration.id
      ) (builtins.attrValues resolvedMoves.entries);
    in {
      schema_version = 1;
      contract = resolvedMoves.contract;
      generation = {phase_projections = resolvedMoves.projections;};
      runtime = {
        plans =
          map (projection: {
            schema_version = 1;
            adapter = "host-phase-projection";
            payload = projection;
          })
          resolvedMoves.projections;
        hosts = resolvedMoves.runtimeHosts;
      };
      admission = {
        enabled = true;
        schema_version = 1;
        adapter = "stateful-service-placement";
        authority_paths = [
          "service-placement-contract.json"
          "desired-resource-states.json"
          "resources.json"
        ];
        document = admission {
          inherit lib;
          baselineStacks = state.context.baselineStacks;
          effectiveStacks = canonicalStacks;
          moveContract = resolvedMoves.contract;
          scopeOwners = contextScopeOwners;
        };
      };
      claims = moveClaims;
      repository = {
        document_kind = "service-move";
        owned_paths = movePaths;
      };
      next_context = {};
    };
  };
}
