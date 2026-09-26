{
  lib,
  adapters,
  fragments,
  initialContext ? {},
  runtimeAdapters ? {},
}: let
  validation = import ../validation;
  inherit (validation) isNonEmptyString;
  inherit (validation.mk "invalid projection domain registry") require requireOnly;
  inherit (import ../validation/paths.nix {inherit lib;}) indexedPairs isRepositoryPath pathsOverlap;
  validateClaim = domain: claim:
    assert require (builtins.isAttrs claim) "domain ${domain} emitted a non-object claim";
    assert requireOnly ["access" "key" "namespace" "overlap" "owner"] claim "domain ${domain} claim";
    assert require (lib.all (field: builtins.hasAttr field claim) ["access" "key" "namespace" "overlap" "owner"]) "domain ${domain} claim must declare access, key, namespace, overlap, and owner";
    assert require (isNonEmptyString claim.namespace) "domain ${domain} claim namespace must be non-empty";
    assert require (isNonEmptyString claim.key) "domain ${domain} claim key must be non-empty";
    assert require (isNonEmptyString claim.owner) "domain ${domain} claim owner must be non-empty";
    assert require (builtins.elem claim.access ["exclusive" "shared"]) "domain ${domain} claim access must be exclusive or shared";
    assert require (builtins.elem claim.overlap ["exact" "path-prefix"]) "domain ${domain} claim overlap must be exact or path-prefix";
      claim // {inherit domain;};
  validateRepository = domain: repository:
    assert require (builtins.isAttrs repository) "domain ${domain} repository contract must be an object";
    assert requireOnly ["document_kind" "owned_paths"] repository "domain ${domain} repository contract";
    assert require (repository ? document_kind) "domain ${domain} repository contract must declare document_kind";
    assert require (repository ? owned_paths) "domain ${domain} repository contract must declare owned_paths";
    assert require (isNonEmptyString repository.document_kind) "domain ${domain} repository document kind must be non-empty";
    assert require (builtins.isList repository.owned_paths && lib.all isRepositoryPath repository.owned_paths) "domain ${domain} owned repository paths must be safe relative paths";
    assert require (builtins.length repository.owned_paths == builtins.length (lib.unique repository.owned_paths)) "domain ${domain} owned repository paths must be unique"; repository;
  validateRuntimePlan = domain: plan:
    assert require (builtins.isAttrs plan) "domain ${domain} emitted a non-object runtime plan";
    assert requireOnly ["adapter" "payload" "schema_version"] plan "domain ${domain} runtime plan";
    assert require (lib.all (field: builtins.hasAttr field plan) ["adapter" "payload" "schema_version"]) "domain ${domain} runtime plan must declare adapter, payload, and schema_version";
    assert require (builtins.isInt plan.schema_version && plan.schema_version >= 1) "domain ${domain} runtime plan schema_version must be a positive integer";
    assert require (isNonEmptyString plan.adapter) "domain ${domain} runtime plan adapter must be non-empty";
    assert require (builtins.hasAttr plan.adapter validatedRuntimeAdapters) "domain ${domain} runtime plan uses unregistered adapter ${plan.adapter}";
    assert require (builtins.elem plan.schema_version validatedRuntimeAdapters.${plan.adapter}.schema_versions) "domain ${domain} runtime plan adapter ${plan.adapter} does not support schema_version ${toString plan.schema_version}";
    assert require (builtins.isAttrs plan.payload) "domain ${domain} runtime plan payload must be an object"; plan;
  validateRuntime = domain: runtime:
    assert require (builtins.isAttrs runtime) "domain ${domain} runtime plan must be an object";
    assert requireOnly ["hosts" "plans"] runtime "domain ${domain} runtime contract";
    assert require (runtime ? plans) "domain ${domain} runtime contract must declare plans";
    assert require (builtins.isList runtime.plans) "domain ${domain} runtime plans must be a list";
    assert require (builtins.isList (runtime.hosts or []) && lib.all isNonEmptyString (runtime.hosts or [])) "domain ${domain} runtime hosts must be strings";
      runtime // {plans = map (validateRuntimePlan domain) runtime.plans;};
  validateAdmission = domain: admission:
    assert require (builtins.isAttrs admission) "domain ${domain} admission view must be an object";
    assert require (builtins.isBool (admission.enabled or null)) "domain ${domain} admission enabled flag must be boolean";
      if admission.enabled
      then
        assert requireOnly ["adapter" "authority_paths" "document" "enabled" "schema_version"] admission "domain ${domain} admission view";
        assert require (admission.schema_version == 1) "domain ${domain} admission schema_version must be 1";
        assert require (isNonEmptyString admission.adapter) "domain ${domain} admission adapter must be non-empty";
        assert require (admission ? document && builtins.isAttrs admission.document) "domain ${domain} enabled admission must declare an object document";
        assert require (builtins.isList admission.authority_paths && lib.all isRepositoryPath admission.authority_paths) "domain ${domain} admission authority paths must be safe relative paths";
        assert require (builtins.length admission.authority_paths == builtins.length (lib.unique admission.authority_paths)) "domain ${domain} admission authority paths must be unique"; admission
      else assert requireOnly ["enabled"] admission "domain ${domain} disabled admission view"; admission;
  validateOutput = domain: rawOutput: let
    output =
      {
        generation = {};
        runtime = {plans = [];};
        admission = {enabled = false;};
        claims = [];
        repository = {
          document_kind = domain;
          owned_paths = [];
        };
        next_context = {};
      }
      // rawOutput;
  in
    assert require (builtins.isAttrs rawOutput) "domain ${domain} adapter returned a non-object";
    assert require (rawOutput ? schema_version) "domain ${domain} output must declare schema_version";
    assert require (rawOutput ? contract) "domain ${domain} output must declare contract";
    assert requireOnly ["admission" "claims" "contract" "generation" "next_context" "repository" "runtime" "schema_version"] output "domain ${domain} output";
    assert require (output.schema_version == 1) "domain ${domain} output schema_version must be 1";
    assert require (builtins.isAttrs output.contract) "domain ${domain} contract must be an object";
    assert require (builtins.isAttrs output.generation) "domain ${domain} generation view must be an object";
    assert require (builtins.isAttrs output.next_context) "domain ${domain} next_context must be an object";
    assert require (builtins.isList output.claims) "domain ${domain} claims must be a list";
      output
      // {
        claims = map (validateClaim domain) output.claims;
        admission = validateAdmission domain output.admission;
        repository = validateRepository domain output.repository;
        runtime = validateRuntime domain output.runtime;
      };
  validateAdapter = domain: adapter:
    assert require (builtins.isAttrs adapter) "domain ${domain} adapter must be an object";
    assert requireOnly ["dependencies" "evaluate" "schema_version"] adapter "domain ${domain} adapter";
    assert require (adapter.schema_version == 1) "domain ${domain} adapter schema_version must be 1";
    assert require (builtins.isList adapter.dependencies && lib.all isNonEmptyString adapter.dependencies) "domain ${domain} dependencies must be strings";
    assert require (builtins.length adapter.dependencies == builtins.length (lib.unique adapter.dependencies)) "domain ${domain} dependencies must be unique";
    assert require (builtins.isFunction adapter.evaluate) "domain ${domain} evaluate must be a function"; adapter;
  validateRuntimeAdapter = name: capability:
    assert require (isNonEmptyString name) "runtime adapter names must be non-empty";
    assert require (builtins.isAttrs capability) "runtime adapter ${name} capability must be an object";
    assert requireOnly ["schema_versions"] capability "runtime adapter ${name} capability";
    assert require (builtins.isList (capability.schema_versions or null)) "runtime adapter ${name} must declare schema_versions";
    assert require (capability.schema_versions != [] && lib.all (version: builtins.isInt version && version >= 1) capability.schema_versions) "runtime adapter ${name} schema_versions must be positive integers";
    assert require (builtins.length capability.schema_versions == builtins.length (lib.unique capability.schema_versions)) "runtime adapter ${name} schema_versions must be unique"; capability;
  validatedRuntimeAdapters = assert require (builtins.isAttrs runtimeAdapters) "runtime adapter capabilities must be an attribute set";
    builtins.mapAttrs validateRuntimeAdapter runtimeAdapters;
  validatedAdapters = builtins.mapAttrs validateAdapter adapters;
  dependencyReferences = builtins.concatLists (lib.mapAttrsToList (domain: adapter:
    map (dependency: {inherit dependency domain;}) adapter.dependencies)
  validatedAdapters);
  missingDependencyReferences =
    builtins.filter (
      reference: !builtins.hasAttr reference.dependency validatedAdapters
    )
    dependencyReferences;
  renderMissingDependency = reference: "${reference.domain} -> ${reference.dependency}";
  # Execution order is derived from declared dependencies, so the registry has
  # one source of truth and cannot disagree with itself. Ties keep
  # attribute-name order, which keeps evaluation deterministic.
  dependencyOrder = adapterSet: let
    names = builtins.attrNames adapterSet;
    step = state: let
      ready =
        builtins.filter (
          name:
            !builtins.elem name state.placed
            && lib.all (dependency: builtins.elem dependency state.placed) adapterSet.${name}.dependencies
        )
        state.pending;
    in
      if ready == []
      then throw "invalid projection domain registry: dependency cycle among ${lib.concatStringsSep ", " state.pending}"
      else {
        placed = state.placed ++ ready;
        pending = builtins.filter (name: !builtins.elem name ready) state.pending;
      };
    iterate = count: state:
      if count == 0 || state.pending == []
      then state
      else iterate (count - 1) (step state);
  in
    (iterate (builtins.length names) {
      placed = [];
      pending = names;
    }).placed;
  validatedOrder = assert require (missingDependencyReferences == []) "domains depend on unregistered domains: ${lib.concatStringsSep ", " (map renderMissingDependency missingDependencyReferences)}";
    dependencyOrder validatedAdapters;
  foldDomain = state: domain: let
    adapter = validatedAdapters.${domain};
    missingDependencies = builtins.filter (dependency: !builtins.elem dependency state.completed) adapter.dependencies;
    hasFragment = builtins.hasAttr domain fragments;
    fragment =
      if hasFragment
      then fragments.${domain}
      else null;
    dependencyDomains = lib.getAttrs adapter.dependencies state.domains;
    dependencyContext = builtins.foldl' (context: dependency: context // state.contexts.${dependency}) {} adapter.dependencies;
    visibleContext = initialContext // dependencyContext;
    output = assert require (missingDependencies == []) "domain ${domain} runs before dependencies: ${lib.concatStringsSep ", " missingDependencies}";
    assert require hasFragment "domain ${domain} has no repository fragment";
      validateOutput domain (adapter.evaluate {
        inherit fragment;
        context = visibleContext;
        domains = dependencyDomains;
      });
    contextCollisions = builtins.filter (name: builtins.hasAttr name state.context) (builtins.attrNames output.next_context);
  in
    assert require (contextCollisions == []) "domain ${domain} overwrites shared context keys: ${lib.concatStringsSep ", " contextCollisions}"; {
      completed = state.completed ++ [domain];
      context = state.context // output.next_context;
      contexts = state.contexts // {${domain} = output.next_context;};
      domains = state.domains // {${domain} = builtins.removeAttrs output ["next_context"];};
      claims = state.claims ++ output.claims;
    };
  folded =
    builtins.foldl' foldDomain {
      completed = [];
      context = initialContext;
      contexts = {};
      domains = {};
      claims = [];
    }
    validatedOrder;
  conflict = pair:
    pair.left.namespace
    == pair.right.namespace
    && (pair.left.domain != pair.right.domain || pair.left.owner != pair.right.owner)
    && (pair.left.access == "exclusive" || pair.right.access == "exclusive")
    && (
      if pair.left.overlap == "path-prefix" || pair.right.overlap == "path-prefix"
      then pathsOverlap pair.left.key pair.right.key
      else pair.left.key == pair.right.key
    );
  conflicts = builtins.filter conflict (indexedPairs folded.claims);
  renderConflict = pair: "${pair.left.domain}:${pair.left.owner} and ${pair.right.domain}:${pair.right.owner} claim namespace ${pair.left.namespace} at keys ${pair.left.key} and ${pair.right.key}";
  repositoryOwners = builtins.concatLists (lib.mapAttrsToList (domain: output:
    map (path: {
      inherit domain path;
      kind = output.repository.document_kind;
    })
    output.repository.owned_paths)
  folded.domains);
  overlappingOwnedPaths = builtins.filter (pair: pathsOverlap pair.left.path pair.right.path) (indexedPairs repositoryOwners);
  result = {
    schema_version = 1;
    domainOrder = validatedOrder;
    inherit (folded) claims context domains;
    repository = {
      schema_version = 1;
      owners = repositoryOwners;
    };
  };
in
  assert require (conflicts == []) "cross-domain claim conflict: ${lib.concatStringsSep "; " (map renderConflict conflicts)}";
  assert require (overlappingOwnedPaths == []) "repository paths overlap across projection owners";
    builtins.deepSeq result result
