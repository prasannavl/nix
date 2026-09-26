{
  projectionScopes ? {},
  projections ? {},
  stacks,
}: let
  validation = import ../validation;
  inherit (validation.mk "invalid prebuilt configuration family") require;
  validateStack = name: stack:
    assert require (builtins.isAttrs stack) "stack ${name} must be an attribute set";
    assert require ((stack.stackName or null) == name) "stack ${name} stackName must match its attribute name"; stack;
  validatedStacks = builtins.mapAttrs validateStack stacks;
in
  assert require (builtins.isAttrs stacks && stacks != {}) "stacks must be a non-empty attribute set";
  assert require (builtins.isAttrs projectionScopes) "projectionScopes must be an attribute set";
  assert require (builtins.isAttrs projections) "projections must be an attribute set";
    builtins.deepSeq validatedStacks {
      stacks = validatedStacks;
      inherit projectionScopes projections;
    }
