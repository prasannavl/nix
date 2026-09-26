{
  # Families group related stack definitions and projection fragments. The
  # fold exposes only normalized stacks, scopes, fabrics, and ownership maps.
  families,
  shared,
  # Repository Nix client policy. Deployment inventory contributes the local
  # cache endpoint later; this manifest owns additional substituters and trust.
  nix ? {},
  # Repository-specific domains extend the mandatory service domains as one
  # registration, so fragment validation and evaluated behavior cannot drift.
  projectionDomainExtensions ? {},
  # Runtime plan executors implemented by the repository's controller. Built-in
  # executors remain owned by the shared projection assembly.
  projectionRuntimeAdapters ? {},
  # Optional operator default for repository-wide logical service lookup. This
  # names a canonical stack scope or a declared placement scope; its stack is
  # derived below so the two values cannot disagree.
  defaultScope ? null,
  # Repository-wide and canonical-stack NixOS module registrations. The root
  # validates this registry against the normalized concrete stack set before
  # selecting modules for a system.
  modules ? {},
}: let
  validation = import ../validation;
  inherit (validation.mk "invalid repository config") require requireOnly uniqueStrings;
  builtInProjectionDomains = import ./projection-domain-specifications.nix;
  builtInProjectionDomainNames = builtins.attrNames builtInProjectionDomains;
  validateProjectionDomainExtension = name: extension:
    assert require (builtins.isAttrs extension) "projection domain extension ${name} must be an attribute set";
    assert requireOnly ["adapter" "specification"] extension "projection domain extension ${name}";
    assert require (extension ? adapter) "projection domain extension ${name} must declare an adapter";
    assert require (extension ? specification) "projection domain extension ${name} must declare a specification"; extension;
  validatedProjectionDomainExtensions = assert require (builtins.isAttrs projectionDomainExtensions) "projection domain extensions must be an attribute set";
    builtins.mapAttrs validateProjectionDomainExtension projectionDomainExtensions;
  projectionDomainExtensionNames = builtins.attrNames validatedProjectionDomainExtensions;
  projectionDomainCollisions = builtins.filter (name: builtins.elem name builtInProjectionDomainNames) projectionDomainExtensionNames;
  projectionDomains = assert require (projectionDomainCollisions == []) "projection domain extensions may not replace built-in domains: ${builtins.concatStringsSep ", " projectionDomainCollisions}";
    builtInProjectionDomains
    // builtins.mapAttrs (_: extension: extension.specification) validatedProjectionDomainExtensions;
  projectionAdapters = builtins.mapAttrs (_: extension: extension.adapter) validatedProjectionDomainExtensions;
  normalizedNix = assert require (builtins.isAttrs nix) "repository nix policy must be an attribute set";
  assert requireOnly ["substituters" "trustedPublicKeys"] nix "repository nix policy"; {
    substituters = uniqueStrings "repository nix substituters" (nix.substituters or []);
    trustedPublicKeys = uniqueStrings "repository nix trusted public keys" (nix.trustedPublicKeys or []);
  };
  repository = import ./repository-fold.nix {
    inherit families projectionDomains shared;
  };
  declaredModuleStacks =
    if builtins.isAttrs modules
    then modules.stacks or {}
    else {};
  moduleStacks =
    if builtins.isAttrs declaredModuleStacks
    then declaredModuleStacks
    else {};
  moduleStackNames = builtins.attrNames moduleStacks;
  unknownModuleStackNames =
    builtins.filter (
      name: !builtins.hasAttr name repository.stacks
    )
    moduleStackNames;
  validDefaultScope =
    defaultScope
    == null
    || (
      builtins.isString defaultScope
      && builtins.hasAttr defaultScope repository.scopeDefinitions
    );
  defaultSelection =
    if defaultScope == null
    then null
    else {
      scope = defaultScope;
      stack = repository.scopeDefinitions.${defaultScope}.stack;
    };
in
  assert builtins.isAttrs modules || throw "repository modules must be an attribute set";
  assert builtins.isAttrs declaredModuleStacks || throw "repository module stacks must be an attribute set";
  assert unknownModuleStackNames == [] || throw "repository modules name unknown stacks: ${builtins.concatStringsSep ", " unknownModuleStackNames}";
  assert validDefaultScope || throw "repository default scope must name a declared projection scope";
  assert builtins.isAttrs projectionRuntimeAdapters || throw "repository projection runtime adapters must be an attribute set";
    repository
    // {
      inherit defaultSelection modules projectionAdapters projectionRuntimeAdapters;
      nix = normalizedNix;
    }
