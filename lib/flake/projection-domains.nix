{
  lib,
  stacks,
  scopeOwners,
  scopeDefinitions,
  inventory,
  repositoryProjections,
  phaseProjectionDirectory ? null,
  extraRuntimeAdapters ? {},
  # Additional domain adapters declared by the repository composition
  # (config/default.nix). Their fragments and scope checks come from the same
  # registered domain specifications as the built-ins.
  extraAdapters ? {},
}: let
  repositoryLayout = (import ./projection-repository.nix).mkRepository {
    inherit lib scopeDefinitions scopeOwners stacks;
  };
  builtInAdapters = import ./projection-built-in-adapters.nix {
    inherit lib repositoryLayout;
  };
  builtInDomainNames = builtins.attrNames builtInAdapters;
  extraDomainNames = builtins.attrNames extraAdapters;
  repositoryDomainNames = builtins.attrNames repositoryProjections;
  extraFragmentNames = builtins.filter (domain: !(builtins.elem domain builtInDomainNames)) repositoryDomainNames;
  extraDomainCollisions = lib.intersectLists builtInDomainNames extraDomainNames;
  fragments = assert extraDomainCollisions == [] || throw "extra projection domains may not replace built-in domains";
  assert lib.sort builtins.lessThan extraDomainNames == lib.sort builtins.lessThan extraFragmentNames || throw "extra projection adapters and fragments must name the same domains"; repositoryProjections;
  adapters = builtInAdapters // extraAdapters;
  builtInRuntimeAdapters = {
    host-phase-projection.schema_versions = [1];
  };
  runtimeAdapterCollisions = lib.intersectLists (builtins.attrNames builtInRuntimeAdapters) (builtins.attrNames extraRuntimeAdapters);
  runtimeAdapters = assert runtimeAdapterCollisions == [] || throw "extra runtime adapters may not replace built-in adapters";
    builtInRuntimeAdapters // extraRuntimeAdapters;
  folded = import ./projection-domain-fold.nix {
    inherit adapters fragments lib runtimeAdapters;
    # Shared runtime inputs are explicit context, so extension adapters read
    # them the same way built-ins read their declared dependencies.
    initialContext = {
      baselineStacks = stacks;
      inherit inventory scopeDefinitions scopeOwners;
      repositoryScopes = repositoryLayout.scopes;
    };
  };
  canonicalStacks = folded.context.canonicalStacks;
  domainValues = map (domain: folded.domains.${domain}) folded.domainOrder;
  runtimePlans = builtins.concatMap (domain: domain.runtime.plans or []) domainValues;
  phaseProjectionDocuments = map (plan: plan.payload) (builtins.filter (plan: plan.adapter == "host-phase-projection") runtimePlans);
  domainRuntimeHosts = lib.unique (builtins.concatMap (domain: domain.runtime.hosts or []) domainValues);
  phaseProjection = import ./phase-projection.nix {
    inherit lib;
    directory = phaseProjectionDirectory;
    documents = phaseProjectionDocuments;
    scopeStacks = canonicalStacks;
  };
  runtimeHosts = lib.unique (phaseProjection.runtimeHosts ++ domainRuntimeHosts);
  effectiveStacks = phaseProjection.applyToStacks canonicalStacks;
  contracts = builtins.mapAttrs (_: domain: domain.contract) folded.domains;
  admission = builtins.mapAttrs (_: domain: domain.admission) folded.domains;
  repository = folded.repository // {scopes = repositoryLayout.scopes;};
in {
  inherit admission contracts effectiveStacks phaseProjection;
  inherit (repositoryLayout) scopeCatalog serviceMoveMutationsFor;
  inherit repository;
  inherit (folded) claims schema_version;
  generation = {
    stacks = effectiveStacks;
    domains = builtins.mapAttrs (_: domain: domain.generation) folded.domains;
  };
  runtime = {
    inherit runtimeHosts;
    plans = runtimePlans;
  };
}
