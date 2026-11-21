{
  lib,
  stacks,
  scopeOwners,
  scopeDefinitions,
  inventory,
  repositoryProjections,
  phaseProjectionDirectory ? null,
  extraRuntimeAdapters ? {},
  extraAdapters ? {},
}: let
  ab = import ../ab;
  repoComponent = ab.repo;
  stackComponent = ab.stack;
in
  repoComponent.projectionDomains {
    inherit
      extraAdapters
      extraRuntimeAdapters
      inventory
      lib
      phaseProjectionDirectory
      repositoryProjections
      scopeDefinitions
      scopeOwners
      stacks
      ;
    serviceStack = stackComponent.serviceStack;
    phaseProjectionFor = stackComponent.phase.projection;
  }
