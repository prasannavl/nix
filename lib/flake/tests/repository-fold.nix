{pkgs}: let
  domain = {
    empty = {};
    validate = helpers: familyName: ownedScopes: fragment:
      assert helpers.require (builtins.isAttrs fragment) "configuration family ${familyName} identities must be an attribute set";
      assert helpers.require (builtins.all (scope: builtins.elem scope ownedScopes) (builtins.attrNames fragment)) "configuration family ${familyName} may only declare identities for its own scopes"; fragment;
    merge = helpers: fragments: helpers.mergeUniqueAttrs "identity profiles" fragments;
  };
  fold = families:
    import ../repository-fold.nix {
      inherit families;
      shared = {};
      projectionDomains.identities = domain;
    };
  valid = fold {
    a = {
      stacks.a = {
        stackName = "a";
        placements.edge.stackName = "a-edge";
      };
      projectionScopes.a-edge = {
        stack = "a";
        placement = "edge";
      };
      projections.identities.a.alice = {displayName = "Alice";};
    };
    b = {
      stacks.b = {stackName = "b";};
      projectionScopes = {};
      projections = {};
    };
  };
  invalid = fold {
    a = {
      stacks.a = {stackName = "a";};
      projectionScopes = {};
      projections.identities.b.alice = {displayName = "Alice";};
    };
  };
  aliasedPlacement = fold {
    a = {
      stacks.a = {
        stackName = "a";
        placements.edge.stackName = "a-edge";
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
        stackName = "a";
        placements.edge.stackName = "a-edge";
      };
      projectionScopes = {};
      projections = {};
    };
    b = {
      stacks.b = {stackName = "b";};
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
        stacks.escape = {stackName = "escape";};
        projectionScopes = {};
        projections = {};
      };
    })
    true);
  mismatchedStackName = builtins.tryEval (builtins.deepSeq (fold {
      a = {
        stacks.a = {stackName = "other";};
        projectionScopes = {};
        projections = {};
      };
    })
    true);
  unsafeScope = builtins.tryEval (builtins.deepSeq (fold {
      a = {
        stacks.a = {
          stackName = "a";
          placements.edge.stackName = "a-edge";
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
    (import ../repository-fold.nix {
      shared = [];
      families.a = {
        stacks.a.stackName = "a";
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
  assert (valid.materializeScopeStacks (valid.scopeStacks // {a-edge.stackName = "projected-edge";})).a.placements.edge.stackName == "projected-edge";
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
