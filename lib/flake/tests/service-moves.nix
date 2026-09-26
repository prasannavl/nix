{pkgs}: let
  mkStack = serviceRole: let
    stack = {
      stackName = "demo";
      serviceRegistry = {
        roles = {
          source.host = "demo-source";
          target.host = "demo-target";
          router.host = "demo-router";
        };
        services.app = {
          role = serviceRole;
          migration = {
            kind = "stateful";
            eligibleRoles = ["source" "target"];
            writerResource = "service:app";
            dataRoots = ["/var/lib/app"];
            route = {
              executorRole = "router";
              resource = "service:router";
            };
          };
        };
      };
      withServiceRoles = overrides: mkStack (overrides.app or serviceRole);
    };
  in
    stack;
  inventory.hosts = {
    source.resourceId = "demo-source";
    target.resourceId = "demo-target";
    router.resourceId = "demo-router";
  };
  sourceStacks.demo = mkStack "source";
  targetStacks.demo = mkStack "target";
  scopeOwners = {demo = "demo";};
  placements = {demo.app = {};};
  basisFor = stacks: service: from: to:
    (import ../service-moves.nix {
      inherit (pkgs) lib;
      inherit inventory placements scopeOwners stacks;
      declarations = {};
    }).contract.basis_catalog.demo.${
      service
    }.${
      from
    }.${
      to
    };
  mkMove = stacks: {
    phase,
    activationAttempt ? 1,
    decision ? null,
    generation ? 4,
    previous ? {
      activation_requirement = null;
      contract_sha256 = null;
      repository_revision = null;
    },
  }: {
    schema_version = 4;
    id = "move-app";
    authority = "controller";
    scope = "demo";
    items = [
      {
        id = "item-001";
        service = "app";
        from = "source";
        to = "target";
        basis_sha256 = basisFor stacks "app" "source" "target";
      }
    ];
    desired = {
      inherit phase;
      activationAttempts.item-001 = {
        source = activationAttempt;
        target = activationAttempt;
      };
      inherit generation;
      leases = {
        item-001 = {
          source =
            if phase == "moved"
            then null
            else 2;
          target = 3;
        };
      };
    };
    inherit decision;
    inherit previous;
  };
  evaluate = stacks: move:
    import ../service-moves.nix {
      inherit (pkgs) lib;
      inherit inventory placements scopeOwners stacks;
      declarations.move-app = move;
    };
  moved = evaluate sourceStacks (mkMove sourceStacks {phase = "moved";});
  prepared = evaluate sourceStacks (mkMove sourceStacks {phase = "prepared";});
  targetActive = evaluate sourceStacks (mkMove sourceStacks {
    phase = "target-active";
    activationAttempt = 1;
    generation = 5;
    previous = previousFor prepared;
  });
  rolledBack = evaluate sourceStacks (mkMove sourceStacks {
    phase = "rolled-back";
    activationAttempt = 1;
    generation = 6;
    previous = previousFor targetActive;
  });
  repeatedRolledBack = evaluate sourceStacks (mkMove sourceStacks {
    phase = "rolled-back";
    activationAttempt = 1;
    generation = 7;
    previous = previousFor rolledBack;
  });
  preparedAgain = evaluate sourceStacks (mkMove sourceStacks {
    phase = "prepared";
    generation = 7;
    previous = previousFor rolledBack;
  });
  adoptingTarget = evaluate targetStacks (mkMove targetStacks {
    phase = "adopting-target";
    activationAttempt = 1;
    decision = "complete";
    generation = 5;
    previous = previousFor prepared;
  });
  adoptingSource = evaluate sourceStacks (mkMove sourceStacks {
    phase = "adopting-source";
    activationAttempt = 1;
    decision = "rollback";
    generation = 6;
    previous = previousFor targetActive;
  });
  legacySchema3 = evaluate sourceStacks (
    (mkMove sourceStacks {phase = "prepared";})
    // {schema_version = 3;}
  );
  projections = map (result: builtins.head result.projections) [
    moved
    prepared
    targetActive
    rolledBack
    repeatedRolledBack
    preparedAgain
    adoptingTarget
    adoptingSource
  ];
  projectionsAreValid = pkgs.lib.all (projection:
    (builtins.tryEval (builtins.deepSeq
      (import ../phase-projection.nix {
        inherit (pkgs) lib;
        documents = [projection];
      }).documents
      true)).success)
  projections;
  resourceState = projection: role:
    (pkgs.lib.findFirst (resource: resource.role == role) null projection.resources).endpoint.desired_state;
  projectionFor = result: builtins.head result.projections;
  previousFor = result: let
    projection = projectionFor result;
  in {
    activation_requirement = projection.activation_requirement;
    contract_sha256 = projection.projection_sha256;
    repository_revision = null;
  };
  invalidStablePlacement = evaluate targetStacks (mkMove targetStacks {phase = "prepared";});
  invalidDecision = evaluate sourceStacks (mkMove sourceStacks {
    phase = "target-active";
    activationAttempt = 1;
    decision = "complete";
    generation = 5;
    previous = previousFor prepared;
  });
  missingItemId = evaluate sourceStacks (
    (mkMove sourceStacks {phase = "moved";})
    // {
      items = [
        (builtins.removeAttrs (builtins.head (mkMove sourceStacks {phase = "moved";}).items) ["id"])
      ];
    }
  );
  missingLeases = evaluate sourceStacks (
    (mkMove sourceStacks {phase = "moved";})
    // {
      desired = builtins.removeAttrs (mkMove sourceStacks {phase = "moved";}).desired ["leases"];
    }
  );
  malformedLease = evaluate sourceStacks (
    (mkMove sourceStacks {phase = "moved";})
    // {
      desired = (mkMove sourceStacks {phase = "moved";}).desired // {leases.item-001 = "invalid";};
    }
  );
  nonServiceStack = evaluate {demo = {stackName = "demo";};} (mkMove sourceStacks {phase = "moved";});
  malformedServiceStacks.demo = {
    stackName = "demo";
    serviceRegistry = {};
  };
  neutralMalformedServiceStack = import ../service-moves.nix {
    inherit (pkgs) lib;
    inherit inventory placements scopeOwners;
    stacks = malformedServiceStacks;
    declarations = {};
  };
  unknownPlacementService = import ../service-moves.nix {
    inherit (pkgs) lib;
    inherit inventory scopeOwners;
    stacks = sourceStacks;
    placements.demo.unknown = {};
    declarations = {};
  };
  malformedServiceStackMove = evaluate malformedServiceStacks (mkMove sourceStacks {phase = "moved";});
  adoptingAdmission = import ../service-placement-admission.nix {
    inherit (pkgs) lib;
    inherit scopeOwners;
    baselineStacks = sourceStacks;
    effectiveStacks = targetStacks;
    moveContract = adoptingTarget.contract;
  };
in
  assert projectionsAreValid;
  assert !(builtins.tryEval (builtins.deepSeq legacySchema3.contract true)).success;
  assert (projectionFor moved).phase == "seeded";
  assert resourceState (projectionFor moved) "source" == "active";
  assert resourceState (projectionFor moved) "target" == "held";
  assert (projectionFor prepared).phase == "prepared";
  assert resourceState (projectionFor prepared) "source" == "held";
  assert resourceState (projectionFor prepared) "target" == "held";
  assert (projectionFor targetActive).phase == "cutover";
  assert resourceState (projectionFor targetActive) "source" == "held";
  assert resourceState (projectionFor targetActive) "target" == "active";
  assert (projectionFor rolledBack).phase == "rolled_back";
  assert (projectionFor targetActive).activation_requirement == (projectionFor prepared).activation_requirement;
  assert (projectionFor repeatedRolledBack).activation_requirement == (projectionFor rolledBack).activation_requirement;
  assert (projectionFor rolledBack).activation_requirement != (projectionFor targetActive).activation_requirement;
  assert (projectionFor preparedAgain).activation_requirement != (projectionFor prepared).activation_requirement;
  assert (builtins.head adoptingTarget.entries.move-app.items).stable_role == "target";
  assert (builtins.head adoptingTarget.entries.move-app.items).selected_role == "target";
  assert projectionFor adoptingTarget == projectionFor targetActive;
  assert (projectionFor adoptingSource).phase == "rolled_back";
  assert resourceState (projectionFor adoptingSource) "source" == "active";
  assert resourceState (projectionFor adoptingSource) "target" == "held";
  assert projectionFor adoptingSource == projectionFor rolledBack;
  assert moved.runtimeHosts
  == [
    "source"
    "target"
    "router"
  ];
  assert !(builtins.tryEval (builtins.deepSeq invalidStablePlacement.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq invalidDecision.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq missingItemId.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq missingLeases.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq malformedLease.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq nonServiceStack.contract true)).success;
  assert neutralMalformedServiceStack.contract.basis_catalog == {};
  assert !(builtins.tryEval (builtins.deepSeq unknownPlacementService.contract true)).success;
  assert !(builtins.tryEval (builtins.deepSeq malformedServiceStackMove.contract true)).success;
  assert adoptingAdmission.placements.demo.app.role == "target";
  assert adoptingAdmission.moves.move-app.phase == "adopting-target";
  assert adoptingAdmission.moves.move-app.decision == "complete";
    pkgs.runCommand "service-moves-flake-test" {} ''
      touch "$out"
    ''
