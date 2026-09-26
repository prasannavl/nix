{pkgs}: let
  document = {
    schema_version = 3;
    placements.demo.app.role = "target";
  };
  placement = {
    stackName = "demo-primary";
    infrastructure.marker = "placement";
    serviceRegistry.roles = stack.serviceRegistry.roles;
    serviceRegistry.services.app.role = "source";
    topology.marker = "placement";
    withServiceRoles = overrides: {
      appliedOverrides = overrides;
      serviceRegistry =
        placement.serviceRegistry
        // {
          services.app =
            placement.serviceRegistry.services.app
            // {role = overrides.app or "source";};
        };
    };
  };
  stack = {
    stackName = "demo";
    infrastructure.marker = "canonical";
    topology.marker = "canonical";
    serviceRegistry.roles = {
      source.host = "demo-source";
      target.host = "demo-target";
      other.host = "demo-other";
    };
    serviceRegistry.services.app = {
      role = "source";
      migration = {
        kind = "stateful";
        eligibleRoles = ["source" "target"];
      };
    };
    withServiceRoles = overrides: {
      appliedOverrides = overrides;
      serviceRegistry =
        stack.serviceRegistry
        // {
          services.app =
            stack.serviceRegistry.services.app
            // {role = overrides.app or "source";};
        };
    };
    placements.primary = placement;
  };
  stacks.demo = stack;
  repositoryFold = import ../repository-fold.nix {
    shared = {};
    families.demo = {
      inherit stacks;
      projectionScopes.demo-primary = {
        stack = "demo";
        placement = "primary";
      };
      projections.identities = {};
    };
    projectionDomains.identities = {
      empty = {};
      validate = _helpers: _familyName: _ownedScopes: fragment: fragment;
      merge = helpers: fragments: helpers.mergeUniqueAttrs "identity profiles" fragments;
    };
  };
  servicePlacements = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit document stacks;
  };
  placed = servicePlacements.applyToStacks {demo = stack;};
  materialized = repositoryFold.materializeScopeStacks (
    servicePlacements.applyToStacks repositoryFold.scopeStacks
  );
  retiredCloseoutField = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit stacks;
    document = document // {closeouts = {};};
  };
  retiredSchema = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit stacks;
    document = {
      schema_version = 2;
      placements.demo.app.role = "target";
    };
  };
  unknownScope = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit stacks;
    document = document // {placements.unknown.app.role = "target";};
  };
  unknownRole = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit stacks;
    document = document // {placements.demo.app.role = "missing";};
  };
  unsafeService = import ../service-placements.nix {
    inherit (pkgs) lib;
    stacks.demo =
      stack
      // {
        serviceRegistry =
          stack.serviceRegistry
          // {
            services = stack.serviceRegistry.services // {"bad/name" = stack.serviceRegistry.services.app;};
          };
      };
    document =
      document
      // {
        placements.demo = {"bad/name" = {role = "source";};};
      };
  };
  ineligibleRole = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit stacks;
    document = document // {placements.demo.app.role = "other";};
  };
  invalidMigrationStack =
    stack
    // {
      serviceRegistry =
        stack.serviceRegistry
        // {
          services =
            stack.serviceRegistry.services
            // {
              app =
                stack.serviceRegistry.services.app
                // {
                  migration =
                    stack.serviceRegistry.services.app.migration
                    // {eligibleRoles = ["source" "target" "missing"];};
                };
            };
        };
    };
  invalidMigrationPlacement = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit document;
    stacks.demo = invalidMigrationStack;
  };
  invalidMigrationAdmission = import ../service-placement-admission.nix {
    inherit (pkgs) lib;
    baselineStacks.demo = invalidMigrationStack;
    effectiveStacks.demo = invalidMigrationStack;
    moveContract.moves = {};
    scopeOwners.demo = "demo";
  };
  otherStack =
    stack
    // {
      stackName = "other";
      serviceRegistry =
        stack.serviceRegistry
        // {
          roles =
            stack.serviceRegistry.roles
            // {missing.host = "other-missing";};
        };
    };
  familyMigrationAdmission = import ../service-placement-admission.nix {
    inherit (pkgs) lib;
    baselineStacks = {
      demo = invalidMigrationStack;
      other = otherStack;
    };
    effectiveStacks = {
      demo = invalidMigrationStack;
      other = otherStack;
    };
    moveContract.moves = {};
    scopeOwners = {
      demo = "family";
      other = "family";
    };
  };
  crossFamilyMigrationAdmission = import ../service-placement-admission.nix {
    inherit (pkgs) lib;
    baselineStacks = {
      demo = invalidMigrationStack;
      other = otherStack;
    };
    effectiveStacks = {
      demo = invalidMigrationStack;
      other = otherStack;
    };
    moveContract.moves = {};
    scopeOwners = {
      demo = "demo-family";
      other = "other-family";
    };
  };
in
  assert servicePlacements.document.schema_version == 3;
  assert placed.demo.appliedOverrides == {app = "target";};
  assert placed.demo.infrastructure.marker == "canonical";
  assert placed.demo.topology.marker == "canonical";
  assert placed.demo.serviceRegistry.services.app.role == "target";
  assert !(placed.demo.placements.primary ? appliedOverrides);
  assert placed.demo.placements.primary.serviceRegistry.services.app.role == "source";
  assert placed.demo.placements.primary.infrastructure.marker == "placement";
  assert placed.demo.placements.primary.topology.marker == "placement";
  assert materialized.demo.serviceRegistry.services.app.role == "target";
  assert materialized.demo.infrastructure.marker == "canonical";
  assert materialized.demo.placements.primary.serviceRegistry.services.app.role == "source";
  assert materialized.demo.placements.primary.infrastructure.marker == "placement";
  assert !(builtins.tryEval (builtins.deepSeq retiredSchema.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq retiredCloseoutField.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq unknownScope.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq unknownRole.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq unsafeService.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq ineligibleRole.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq invalidMigrationPlacement.document true)).success;
  assert !(builtins.tryEval (builtins.deepSeq invalidMigrationAdmission true)).success;
  assert builtins.deepSeq familyMigrationAdmission true;
  assert !(builtins.tryEval (builtins.deepSeq crossFamilyMigrationAdmission true)).success;
  assert !(builtins.tryEval (builtins.deepSeq (servicePlacements.applyToStacks {}) true)).success;
    pkgs.runCommand "service-placements-flake-test" {} ''
      touch "$out"
    ''
