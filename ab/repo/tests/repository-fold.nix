{pkgs}: let
  repoComponent = import ../../../ab/repo {core = import ../../../ab/core;};
  repositoryFold = repoComponent.fold;
  domain = {
    empty = {};
    validate = helpers: familyName: ownedScopes: fragment:
      assert helpers.require (builtins.isAttrs fragment) "config family ${familyName} identities must be an attribute set";
      assert helpers.require (builtins.all (scope: builtins.elem scope ownedScopes) (builtins.attrNames fragment)) "config family ${familyName} may only declare identities for its own scopes"; fragment;
    merge = helpers: fragments: helpers.mergeUniqueAttrs "identity profiles" fragments;
  };
  fold = families:
    repositoryFold {
      inherit families;
      shared = {};
      projectionDomains.identities = domain;
    };
  valid = fold {
    a = {
      stacks.a = {
        name = "a";
        topology.placements.edge.name = "a-edge";
      };
      projectionScopes.a-edge = {
        stack = "a";
        placement = "edge";
      };
      projections.identities.a.alice = {displayName = "Alice";};
    };
    b = {
      stacks.b = {name = "b";};
      projectionScopes = {};
      projections = {};
    };
  };
  invalid = fold {
    a = {
      stacks.a = {name = "a";};
      projectionScopes = {};
      projections.identities.b.alice = {displayName = "Alice";};
    };
  };
  aliasedPlacement = fold {
    a = {
      stacks.a = {
        name = "a";
        topology.placements.edge.name = "a-edge";
      };
      projectionScopes = {
        edge-a = {
          stack = "a";
          placement = "edge";
        };
        edge-b = {
          stack = "a";
          placement = "edge";
        };
      };
      projections = {};
    };
  };
  crossFamilyPlacement = fold {
    a = {
      stacks.a = {
        name = "a";
        topology.placements.edge.name = "a-edge";
      };
      projectionScopes = {};
      projections = {};
    };
    b = {
      stacks.b = {name = "b";};
      projectionScopes.a-edge = {
        stack = "a";
        placement = "edge";
      };
      projections = {};
    };
  };
  emptyFamilies = builtins.tryEval (builtins.deepSeq (fold {}) true);
  unsafeFamily = builtins.tryEval (builtins.deepSeq (fold {
      "../escape" = {
        stacks.escape = {name = "escape";};
        projectionScopes = {};
        projections = {};
      };
    })
    true);
  mismatchedStackName = builtins.tryEval (builtins.deepSeq (fold {
      a = {
        stacks.a = {name = "other";};
        projectionScopes = {};
        projections = {};
      };
    })
    true);
  unsafeScope = builtins.tryEval (builtins.deepSeq (fold {
      a = {
        stacks.a = {
          name = "a";
          topology.placements.edge.name = "a-edge";
        };
        projectionScopes."-edge" = {
          stack = "a";
          placement = "edge";
        };
        projections = {};
      };
    })
    true);
  invalidShared = builtins.tryEval (builtins.deepSeq
    (repositoryFold {
      shared = [];
      families.a = {
        stacks.a.name = "a";
        projectionScopes = {};
        projections = {};
      };
      projectionDomains.identities = domain;
    })
    true);
in
  assert builtins.attrNames valid.stacks == ["a" "b"];
  assert builtins.attrNames valid.scopeStacks == ["a" "a-edge" "b"];
  assert {
    a = valid.scopeOwners.a;
    b = valid.scopeOwners.b;
  }
  == {
    a = "a";
    b = "b";
  };
  assert valid.scopeOwners.a-edge == "a";
  assert valid.shared == {};
  assert !(valid.stacks.a ? placements);
  assert builtins.attrNames valid.stacks.a.topology.placements == ["edge"];
  assert (valid.materializeScopeStacks (valid.scopeStacks // {a-edge.name = "projected-edge";})).a.topology.placements.edge.name == "projected-edge";
  assert builtins.attrNames (valid.materializeScopeStacks valid.scopeStacks) == ["a" "b"];
  assert builtins.attrNames valid.projections.identities == ["a"];
  assert !(builtins.tryEval (builtins.deepSeq invalid true)).success;
  assert !(builtins.tryEval (builtins.deepSeq aliasedPlacement true)).success;
  assert !(builtins.tryEval (builtins.deepSeq crossFamilyPlacement true)).success;
  assert !emptyFamilies.success;
  assert !unsafeFamily.success;
  assert !mismatchedStackName.success;
  assert !unsafeScope.success;
  assert !invalidShared.success;
    pkgs.runCommand "repository-fold-test" {} ''
      touch "$out"
    ''
