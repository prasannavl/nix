{validation}: {
  lib,
  repoModules ? {},
  stacks ? {},
}: let
  inherit (validation.mk "invalid repository modules") require requireOnly;
  duplicateValues = values:
    builtins.attrNames (
      lib.filterAttrs (_: count: count > 1) (
        builtins.foldl'
        (acc: value: let
          key = toString value;
        in
          acc // {${key} = (acc.${key} or 0) + 1;})
        {}
        values
      )
    );
  validateLayer = context: modules:
    assert require (builtins.isAttrs modules) "${context} must be an attribute set";
    assert require (builtins.all (name: name != "") (builtins.attrNames modules)) "${context} has an empty module name";
    assert require (builtins.all builtins.isPath (builtins.attrValues modules)) "${context} values must be module paths";
    assert require (builtins.all builtins.pathExists (builtins.attrValues modules)) "${context} contains a missing module path";
    assert require (duplicateValues (builtins.attrValues modules) == []) "${context} registers the same module path more than once"; modules;
  declared = {
    repo = repoModules.repo or {};
    stacks = repoModules.stacks or {};
  };
  stackNames = builtins.attrNames stacks;
  declaredStackNames = builtins.attrNames declared.stacks;
  unknownStackNames = builtins.filter (name: !builtins.elem name stackNames) declaredStackNames;
  validated = {
    repo = validateLayer "repo" declared.repo;
    stacks = builtins.mapAttrs (name: validateLayer "stack ${name}") declared.stacks;
  };
  validateStackOverlap = stackName: modules: let
    duplicateNames = builtins.attrNames (builtins.intersectAttrs validated.repo modules);
    duplicatePaths =
      builtins.filter
      (path: builtins.elem path (map toString (builtins.attrValues validated.repo)))
      (map toString (builtins.attrValues modules));
  in
    assert require (duplicateNames == []) "stack ${stackName} duplicates repo module names: ${builtins.concatStringsSep ", " duplicateNames}";
    assert require (duplicatePaths == []) "stack ${stackName} duplicates a repo module path"; modules;
  validatedStacks = builtins.mapAttrs validateStackOverlap validated.stacks;
  registry = {
    inherit (validated) repo;
    stacks = validatedStacks;
  };
  registeredPaths =
    builtins.attrValues registry.repo
    ++ lib.concatMap builtins.attrValues (builtins.attrValues registry.stacks);
  duplicateRegisteredPaths = duplicateValues registeredPaths;
  modulesFor = stack: let
    validStack = stack == null || builtins.isAttrs stack;
    hasName = stack == null || (validStack && stack ? name);
    effectiveName =
      if stack == null || !hasName
      then null
      else stack.name;
    validName = stack == null || (hasName && builtins.isString effectiveName);
    knownStack = validName && (stack == null || builtins.elem effectiveName stackNames);
    stackModules =
      if effectiveName == null
      then {}
      else registry.stacks.${effectiveName} or {};
  in
    assert require validStack "effective stack must be an attribute set";
    assert require hasName "effective stack must declare name";
    assert require validName "effective stack name must be a string";
    assert require knownStack "effective stack ${effectiveName} is not declared";
      builtins.attrValues registry.repo ++ builtins.attrValues stackModules;
in
  assert require (builtins.isAttrs stacks) "stacks must be an attribute set";
  assert require (builtins.isAttrs repoModules) "composition must be an attribute set";
  assert requireOnly ["repo" "stacks"] repoModules "composition";
  assert require (builtins.isAttrs declared.stacks) "stacks must be an attribute set";
  assert require (unknownStackNames == []) "unknown stacks: ${builtins.concatStringsSep ", " unknownStackNames}";
  assert require (duplicateRegisteredPaths == []) "module paths may be registered only once: ${builtins.concatStringsSep ", " duplicateRegisteredPaths}";
    builtins.deepSeq registry {
      inherit modulesFor registry;
    }
