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
  mkMove = {
    phase,
    activationAttempt ? 0,
    decision ? null,
  }: {
    schema_version = 1;
    id = "move-app";
    authority = "controller";
    scope = "demo";
    services = ["app"];
    from = "source";
    to = "target";
    desired = {
      inherit activationAttempt phase;
      generation = 4;
      leases = {
        source =
          if phase == "moved"
          then null
          else 2;
        target = 3;
      };
    };
    inherit decision;
    previous = {
      contract_sha256 = null;
      repository_revision = null;
    };
  };
  evaluate = stacks: move:
    import ../service-moves.nix {
      inherit (pkgs) lib;
      inherit inventory stacks;
      declarations.move-app = move;
    };
  moved = evaluate sourceStacks (mkMove {phase = "moved";});
  prepared = evaluate sourceStacks (mkMove {phase = "prepared";});
  targetActive = evaluate sourceStacks (mkMove {
    phase = "target-active";
    activationAttempt = 1;
  });
  rolledBack = evaluate sourceStacks (mkMove {
    phase = "rolled-back";
    activationAttempt = 1;
  });
  adoptingTarget = evaluate targetStacks (mkMove {
    phase = "adopting-target";
    activationAttempt = 1;
    decision = "complete";
  });
  adoptingSource = evaluate sourceStacks (mkMove {
    phase = "adopting-source";
    activationAttempt = 1;
    decision = "rollback";
  });
  projections = map (result: builtins.head result.projections) [
    moved
    prepared
    targetActive
    rolledBack
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
  invalidStablePlacement = evaluate targetStacks (mkMove {phase = "prepared";});
  invalidDecision = evaluate sourceStacks (mkMove {
    phase = "target-active";
    activationAttempt = 1;
    decision = "complete";
  });
  adoptingAdmission = import ../service-placement-admission.nix {
    inherit (pkgs) lib;
    baselineStacks = sourceStacks;
    effectiveStacks = targetStacks;
    moveContract = adoptingTarget.contract;
  };
in
  assert projectionsAreValid;
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
  assert adoptingTarget.entries.move-app.stable_role == "target";
  assert adoptingTarget.entries.move-app.selected_role == "target";
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
  assert adoptingAdmission.placements.demo.app.role == "target";
  assert adoptingAdmission.moves.move-app.phase == "adopting-target";
  assert adoptingAdmission.moves.move-app.decision == "complete";
    pkgs.runCommand "service-moves-flake-test" {} ''
      touch "$out"
    ''
