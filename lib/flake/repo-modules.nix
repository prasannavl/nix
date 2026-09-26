{
  lib,
  repoModules ? {},
  stacks ? {},
}: let
  validation = import ../validation;
  inherit (validation.mk "invalid repository modules") require requireOnly;
  inherit (import ./utils.nix {inherit lib;}) duplicateValues;
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
    hasStackName = stack == null || (validStack && stack ? stackName);
    stackName =
      if stack == null || !hasStackName
      then null
      else stack.stackName;
    validStackName = stack == null || (hasStackName && builtins.isString stackName);
    knownStack = validStackName && (stack == null || builtins.elem stackName stackNames);
    stackModules =
      if stackName == null
      then {}
      else registry.stacks.${stackName} or {};
  in
    assert require validStack "effective stack must be an attribute set";
    assert require hasStackName "effective stack must declare stackName";
    assert require validStackName "effective stack stackName must be a string";
    assert require knownStack "effective stack ${stackName} is not declared";
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
