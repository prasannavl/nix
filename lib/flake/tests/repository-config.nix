/*
Generic repository-configuration contract: the structural invariants every
repository composition must satisfy, asserted without naming any repository's
families, stacks, or scopes. Repository-specific topology assertions live in
the owning identity directory (lib/flake/tests/<topology>/), never here. See
.agents/docs/design-patterns/shared-test-areas.md.
*/
{
  pkgs,
  repositoryConfig,
}: let
  stackNames = builtins.attrNames repositoryConfig.stacks;
  scopeNames = builtins.attrNames repositoryConfig.scopeStacks;
  canonicalScopeOwners = builtins.listToAttrs (map (stack: {
      name = stack;
      value = repositoryConfig.scopeOwners.${stack};
    })
    stackNames);
  familyNames = builtins.attrNames (
    builtins.groupBy (family: family) (builtins.attrValues canonicalScopeOwners)
  );
  require = condition: message:
    assert condition || throw "repository config contract: ${message}"; true;
  repositoryConfigArgs = builtins.functionArgs (import ../repository-config.nix);
  extensionDomain = {
    empty = {};
    validate = helpers: familyName: ownedScopes: fragment:
      assert helpers.require (builtins.isAttrs fragment) "configuration family ${familyName} identities must be an attribute set";
      assert helpers.require (builtins.all (scope: builtins.elem scope ownedScopes) (builtins.attrNames fragment)) "configuration family ${familyName} may only declare identities for its own scopes"; fragment;
    merge = helpers: fragments: helpers.mergeUniqueAttrs "identity profiles" fragments;
  };
  extensionRepository = import ../repository-config.nix {
    shared = {};
    defaultScope = "fixture";
    families.fixture = {
      stacks.fixture = {stackName = "fixture";};
      projectionScopes = {};
      projections.identities = {};
    };
    projectionDomainExtensions.identities = {
      specification = extensionDomain;
      adapter = {
        schema_version = 1;
        dependencies = [];
        evaluate = _: {};
      };
    };
  };
  invalidDefaultScope = builtins.tryEval (builtins.deepSeq
    (import ../repository-config.nix {
      shared = {};
      defaultScope = "missing";
      families.fixture = {
        stacks.fixture = {stackName = "fixture";};
        projectionScopes = {};
        projections.identities = {};
      };
      projectionDomainExtensions.identities = {
        specification = extensionDomain;
        adapter = {
          schema_version = 1;
          dependencies = [];
          evaluate = _: {};
        };
      };
    })
    true);
  emptyFamilies = builtins.tryEval (builtins.deepSeq
    (import ../repository-config.nix {
      shared = {};
      families = {};
    })
    true);
  builtInCollision = builtins.tryEval (builtins.deepSeq
    (import ../repository-config.nix {
      shared = {};
      families.fixture = {
        stacks.fixture = {stackName = "fixture";};
        projectionScopes = {};
        projections = {};
      };
      projectionDomainExtensions.serviceMoves = {
        specification = extensionDomain;
        adapter = {};
      };
    })
    true);
  minimalRepositoryArgs = {
    shared = {};
    families.fixture = {
      stacks.fixture = {stackName = "fixture";};
      projectionScopes = {};
      projections = {};
    };
  };
  tryNixPolicy = nix:
    builtins.tryEval (builtins.deepSeq
      (import ../repository-config.nix (minimalRepositoryArgs // {inherit nix;}))
      true);
  validNixPolicy = import ../repository-config.nix (minimalRepositoryArgs
    // {
      nix = {
        substituters = ["https://cache.example.test"];
        trustedPublicKeys = ["cache.example.test-1:key"];
      };
    });
  unknownNixPolicyField = tryNixPolicy {typo = [];};
  duplicateNixSubstituter = tryNixPolicy {
    substituters = [
      "https://cache.example.test"
      "https://cache.example.test"
    ];
  };
  emptyNixPublicKey = tryNixPolicy {trustedPublicKeys = [""];};
in
  assert require (familyNames != []) "at least one configuration family is required";
  assert require (stackNames != []) "configuration families must declare at least one stack";
  assert require (builtins.attrNames canonicalScopeOwners == stackNames) "every stack must have exactly one repository owner";
  assert require (builtins.attrNames repositoryConfig.scopeDefinitions == scopeNames) "every scope must have a definition";
  assert require (builtins.attrNames repositoryConfig.scopeOwners == scopeNames) "every scope must have an owner";
  assert require (builtins.all (owner: builtins.elem owner familyNames) (builtins.attrValues repositoryConfig.scopeOwners)) "scope owners must name stack-owning configuration families";
  assert require (builtins.all (definition: builtins.elem definition.stack stackNames) (builtins.attrValues repositoryConfig.scopeDefinitions)) "scope definitions must reference declared stacks";
  assert require (builtins.attrNames repositoryConfig.projections != []) "at least one projection domain must be registered";
  assert require (builtins.isAttrs repositoryConfig.modules) "repository modules must be an attribute set";
  assert require (builtins.all (name: builtins.hasAttr name repositoryConfig.stacks) (builtins.attrNames (repositoryConfig.modules.stacks or {}))) "repository module stacks must name declared stacks";
  assert require (builtins.isAttrs repositoryConfig.shared) "repository shared data must be an attribute set";
  assert require (builtins.attrNames repositoryConfig.nix == ["substituters" "trustedPublicKeys"]) "repository nix policy must be normalized";
  assert require (builtins.isList repositoryConfig.nix.substituters) "repository nix substituters must be a list";
  assert require (builtins.isList repositoryConfig.nix.trustedPublicKeys) "repository nix trusted public keys must be a list";
  assert require (validNixPolicy.nix
    == {
      substituters = ["https://cache.example.test"];
      trustedPublicKeys = ["cache.example.test-1:key"];
    }) "repository nix policy must preserve validated values";
  assert require (!unknownNixPolicyField.success) "repository nix policy must reject unknown fields";
  assert require (!duplicateNixSubstituter.success) "repository nix policy must reject duplicate substituters";
  assert require (!emptyNixPublicKey.success) "repository nix policy must reject empty public keys";
  assert require (repositoryConfig.defaultSelection == null || builtins.hasAttr repositoryConfig.defaultSelection.scope repositoryConfig.scopeDefinitions) "the default selection must be absent or declared";
  assert require (builtins.attrNames extensionRepository.projections == ["identities" "serviceMoves" "servicePlacements"]) "repositories must extend the mandatory projection-domain registry";
  assert require (extensionRepository.projectionAdapters.identities.schema_version == 1) "repositories must retain extension adapters";
  assert require (extensionRepository.defaultSelection
    == {
      scope = "fixture";
      stack = "fixture";
    }) "the default selection must derive from the default scope";
  assert require (!invalidDefaultScope.success) "an unknown default scope must fail";
  assert require (!emptyFamilies.success) "deployment repository configuration must declare a family";
  assert require (repositoryConfigArgs.shared == false) "repository configuration must require shared data";
  assert require (repositoryConfigArgs.families == false) "repository configuration must require family declarations";
  assert require (!(repositoryConfig ? families)) "raw family declarations must remain internal";
  assert require (!(repositoryConfig ? stackOwners)) "stack ownership must not duplicate canonical scope ownership";
  assert require (!builtInCollision.success) "extension domains may not replace mandatory domains";
    pkgs.runCommand "lib-flake-repository-config-test" {} ''
      touch "$out"
    ''
