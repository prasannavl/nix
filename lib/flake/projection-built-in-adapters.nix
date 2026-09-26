{
  lib,
  repositoryLayout,
}: {
  servicePlacements = {
    schema_version = 1;
    dependencies = [];
    evaluate = state: let
      baselineStacks = state.context.baselineStacks;
      placement = import ./service-placements.nix {
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
      moves = import ./service-moves.nix {
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
      (builtins.attrValues moves.entries);
      movePaths = map (
        entry: repositoryLayout.movePathFor entry.declaration.scope entry.declaration.id
      ) (builtins.attrValues moves.entries);
    in {
      schema_version = 1;
      contract = moves.contract;
      generation = {phase_projections = moves.projections;};
      runtime = {
        plans =
          map (projection: {
            schema_version = 1;
            adapter = "host-phase-projection";
            payload = projection;
          })
          moves.projections;
        hosts = moves.runtimeHosts;
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
        document = import ./service-placement-admission.nix {
          inherit lib;
          baselineStacks = state.context.baselineStacks;
          effectiveStacks = canonicalStacks;
          moveContract = moves.contract;
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
