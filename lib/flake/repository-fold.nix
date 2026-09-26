{
  shared,
  families,
  projectionDomains,
}: let
  validation = import ../validation;
  inherit (validation) isName;
  inherit (validation.mk "invalid repository config") require requireOnly uniqueStrings;
  requireName = kind: name: require (isName name) "${kind} ${name} must match [A-Za-z0-9][A-Za-z0-9_-]* and be at most 64 characters";
  mergeUniqueAttrs = context: values:
    builtins.foldl' (acc: value: let
      duplicates = builtins.filter (key: builtins.hasAttr key acc) (builtins.attrNames value);
    in
      assert require (duplicates == []) "${context} duplicates: ${builtins.concatStringsSep ", " duplicates}";
        acc // value)
    {}
    values;
  helpers = {
    inherit mergeUniqueAttrs require requireOnly uniqueStrings;
  };
  projectionDomainNames = builtins.attrNames projectionDomains;
  familyNames = builtins.attrNames families;
  validateFamily = name: family:
    assert requireName "configuration family name" name;
    assert require (builtins.isAttrs family) "configuration family ${name} must be an attribute set";
    assert requireOnly ["fabric" "stacks" "projectionScopes" "projections"] family "configuration family ${name}";
    assert require (!(family ? fabric) || builtins.isAttrs family.fabric) "configuration family ${name} fabric must be an attribute set";
    assert require (builtins.isAttrs family.stacks) "configuration family ${name} stacks must be an attribute set";
    assert require (family.stacks != {}) "configuration family ${name} must declare at least one stack";
    assert require (builtins.isAttrs family.projectionScopes) "configuration family ${name} projectionScopes must be an attribute set";
    assert require (builtins.isAttrs family.projections) "configuration family ${name} projections must be an attribute set";
    assert requireOnly projectionDomainNames family.projections "configuration family ${name} projections"; family;
  validateProjectionDomain = name: specification:
    assert requireName "projection domain name" name;
    assert require (builtins.isAttrs specification) "projection domain ${name} must be an attribute set";
    assert requireOnly ["empty" "merge" "validate"] specification "projection domain ${name}";
    assert require (builtins.isFunction specification.validate) "projection domain ${name} validate must be a function";
    assert require (builtins.isFunction specification.merge) "projection domain ${name} merge must be a function";
    assert require (specification ? empty) "projection domain ${name} must declare a neutral fragment"; specification;
  validatedProjectionDomains = builtins.mapAttrs validateProjectionDomain projectionDomains;
  validatedFamilies = builtins.mapAttrs validateFamily families;
  unvalidatedStacks = mergeUniqueAttrs "stacks" (map (name: validatedFamilies.${name}.stacks) familyNames);
  concreteStacks = builtins.mapAttrs (name: stack:
    assert requireName "stack name" name;
    assert require (builtins.isAttrs stack) "stack ${name} must be an attribute set";
    assert require ((stack.stackName or null) == name) "stack ${name} stackName must match its attribute name"; stack)
  unvalidatedStacks;
  stacks = concreteStacks;
  stackFamilies = builtins.listToAttrs (
    builtins.concatMap (
      familyName:
        map (stackName: {
          name = stackName;
          value = familyName;
        }) (builtins.attrNames validatedFamilies.${familyName}.stacks)
    )
    familyNames
  );
  validatePlacementScope = familyName: name: declaration: let
    stackName = declaration.stack or null;
    placementName = declaration.placement or null;
    stack = concreteStacks.${stackName} or null;
  in
    assert requireName "projection scope name" name;
    assert require (builtins.isAttrs declaration) "projection scope ${name} must be an attribute set";
    assert requireOnly ["stack" "placement"] declaration "projection scope ${name}";
    assert require (builtins.isString stackName && stack != null) "projection scope ${name} references an unknown stack";
    assert require (stackFamilies.${stackName} == familyName) "configuration family ${familyName} projection scope ${name} may only target a stack in that family";
    assert require (builtins.isString placementName && builtins.hasAttr placementName (stack.placements or {})) "projection scope ${name} references an unknown placement"; declaration;
  placementScopes = mergeUniqueAttrs "projection scopes" (
    map
    (familyName:
      builtins.mapAttrs
      (validatePlacementScope familyName)
      validatedFamilies.${familyName}.projectionScopes)
    familyNames
  );
  placementScopeTargets =
    builtins.mapAttrs (
      _: declaration: "${declaration.stack}/${declaration.placement}"
    )
    placementScopes;
  placementScopeTargetNames = builtins.attrValues placementScopeTargets;
  duplicatePlacementScopeTargets = builtins.filter (
    target:
      builtins.length (
        builtins.filter (candidate: candidate == target) placementScopeTargetNames
      )
      > 1
  ) (builtins.attrNames (builtins.groupBy (target: target) placementScopeTargetNames));
  canonicalScopes =
    builtins.mapAttrs (stack: _: {
      stack = stack;
      placement = null;
    })
    concreteStacks;
  scopeDefinitions = assert require (duplicatePlacementScopeTargets == []) "projection scopes may not alias the same stack placement: ${builtins.concatStringsSep ", " duplicatePlacementScopeTargets}";
  assert require (builtins.all (name: !builtins.hasAttr name canonicalScopes) (builtins.attrNames placementScopes)) "projection scopes may not shadow stack names";
    canonicalScopes // placementScopes;
  scopeStacks = builtins.mapAttrs (_: definition:
    if definition.placement == null
    then concreteStacks.${definition.stack}
    else concreteStacks.${definition.stack}.placements.${definition.placement})
  scopeDefinitions;
  scopeOwners = builtins.mapAttrs (_: definition: stackFamilies.${definition.stack}) scopeDefinitions;
  ownedScopesFor = familyName:
    builtins.filter (scope: scopeOwners.${scope} == familyName) (builtins.attrNames scopeDefinitions);
  validatedProjectionFragments =
    builtins.mapAttrs
    (domain: specification:
      map
      (familyName:
        specification.validate
        helpers
        familyName
        (ownedScopesFor familyName)
        (validatedFamilies.${familyName}.projections.${domain} or specification.empty))
      familyNames)
    validatedProjectionDomains;
  projections = builtins.mapAttrs (domain: specification:
    specification.merge helpers validatedProjectionFragments.${domain})
  validatedProjectionDomains;
  materializeScopeStacks = effectiveScopes: let
    canonical = builtins.mapAttrs (stackName: _: effectiveScopes.${stackName}) concreteStacks;
  in
    builtins.foldl'
    (result: scopeName: let
      definition = placementScopes.${scopeName};
      stack = result.${definition.stack};
    in
      result
      // {
        ${definition.stack} =
          stack
          // {
            placements =
              stack.placements
              // {${definition.placement} = effectiveScopes.${scopeName};};
          };
      })
    canonical
    (builtins.attrNames placementScopes);
  fabrics = builtins.listToAttrs (
    map
    (familyName: {
      name = familyName;
      value = validatedFamilies.${familyName}.fabric;
    })
    (builtins.filter (familyName: validatedFamilies.${familyName} ? fabric) familyNames)
  );
  result = {
    inherit
      fabrics
      materializeScopeStacks
      projections
      scopeDefinitions
      scopeOwners
      scopeStacks
      shared
      stacks
      ;
  };
in
  assert require (builtins.isAttrs shared) "repository shared data must be an attribute set";
  assert require (builtins.isAttrs families && families != {}) "at least one configuration family is required";
  assert require (builtins.isAttrs projectionDomains && projectionDomains != {}) "at least one projection domain is required";
    builtins.deepSeq {
      inherit fabrics projections scopeDefinitions scopeOwners scopeStacks shared stacks validatedProjectionFragments;
    }
    result
