let
  servicePlacementsEmpty = {
    placements = {};
  };
in {
  servicePlacements = {
    empty = servicePlacementsEmpty;
    validate = helpers: familyName: ownedScopes: fragment: let
      normalized = servicePlacementsEmpty // fragment;
    in
      assert helpers.require (builtins.isAttrs fragment) "configuration family ${familyName} servicePlacements must be an attribute set";
      assert helpers.requireOnly ["placements"] fragment "configuration family ${familyName} servicePlacements";
      assert helpers.require (builtins.isAttrs normalized.placements) "configuration family ${familyName} service placements must be an attribute set";
      assert helpers.require (builtins.all (scope: builtins.elem scope ownedScopes) (builtins.attrNames normalized.placements)) "configuration family ${familyName} may only declare placements for its own scopes"; normalized;
    merge = helpers: fragments: {
      schema_version = 3;
      placements = helpers.mergeUniqueAttrs "service placement scopes" (map (fragment: fragment.placements) fragments);
    };
  };
  serviceMoves = {
    empty = {};
    validate = helpers: familyName: ownedScopes: fragment:
      assert helpers.require (builtins.isAttrs fragment) "configuration family ${familyName} serviceMoves must be an attribute set";
      assert helpers.require (builtins.all (scope: builtins.isString scope && builtins.elem scope ownedScopes) (map (move: move.scope or null) (builtins.attrValues fragment))) "configuration family ${familyName} may only declare moves for its own projection scopes"; fragment;
    merge = helpers: fragments: helpers.mergeUniqueAttrs "service move declarations" fragments;
  };
}
