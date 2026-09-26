let
  validation = import ../validation;
  inherit (validation) isName;
  importDirectory = import ./import-directory.nix;

  mkFamilyLayout = {
    owner,
    root ? null,
    placementScopes ? [],
  }: let
    moveDirectory = "config/${owner}/moves";
    placementDirectoryFor = scope: "config/${owner}/placements/${scope}";
    stacks =
      if root == null
      then null
      else importDirectory (root + "/stacks");
    importedPlacementScopes =
      if stacks == null
      then placementScopes
      else builtins.attrNames stacks ++ placementScopes;
    uniquePlacementScopes = builtins.attrNames (builtins.groupBy (scope: scope) importedPlacementScopes);
    validScopes =
      builtins.isList placementScopes
      && builtins.all isName placementScopes
      && builtins.length placementScopes == builtins.length (builtins.attrNames (builtins.groupBy (scope: scope) placementScopes));
    validRoot =
      root
      == null
      || (
        builtins.isPath root
        && builtins.match ".*/config/${owner}" (toString root) != null
      );
  in
    assert isName owner || throw "invalid projection repository layout: owner must be a safe repository component";
    assert validScopes || throw "invalid projection repository layout: placement scopes must be unique safe repository components";
    assert validRoot || throw "invalid projection repository layout: root must select config/${owner}";
    assert builtins.all isName uniquePlacementScopes || throw "invalid projection repository layout: stack names must be safe repository components"; {
      inherit moveDirectory placementDirectoryFor;
      movePathFor = transaction: "${moveDirectory}/${transaction}.nix";
      placementPathFor = scope: service: "${placementDirectoryFor scope}/${service}.nix";
      inherit stacks;
      moves =
        if root == null
        then null
        else importDirectory (root + "/moves");
      placements =
        if root == null
        then null
        else
          builtins.listToAttrs (map (scope: {
              name = scope;
              value = importDirectory (root + "/placements/${scope}");
            })
            uniquePlacementScopes);
    };

  mkRepository = {
    lib,
    stacks,
    scopeOwners,
    scopeDefinitions,
  }: let
    inherit (validation.mk "invalid service-move repository mutation request") require requireOnly;
    inherit (import ./service-stack.nix) isServiceStack;

    ownerFor = scope:
      scopeOwners.${scope}
        or (throw "projection scope ${scope} has no repository owner");
    layoutFor = owner:
      mkFamilyLayout {inherit owner;};

    scopes =
      builtins.mapAttrs (scope: _: let
        owner = ownerFor scope;
        layout = layoutFor owner;
      in {
        inherit owner;
        move_directory = layout.moveDirectory;
        placement_directory = layout.placementDirectoryFor scope;
      })
      scopeDefinitions;

    scopeCatalog =
      builtins.mapAttrs (scope: definition: {
        stack = definition.stack;
        placement = definition.placement;
        owner = ownerFor scope;
        repository = scopes.${scope};
      })
      scopeDefinitions;

    placementPathFor = scope: service: (layoutFor (ownerFor scope)).placementPathFor scope service;
    movePathFor = scope: transaction: (layoutFor (ownerFor scope)).movePathFor transaction;

    serviceMoveMutationsFor = request:
      assert require (builtins.isAttrs request) "request must be an object";
      assert requireOnly ["owner" "schema_version" "scope" "services" "transaction"] request "request"; let
        scope = request.scope or "";
        owner = request.owner or "";
        services = request.services or null;
        transaction = request.transaction or "";
        stack = stacks.${scope} or null;
        sortedServices =
          if builtins.isList services
          then lib.sort builtins.lessThan services
          else [];
        unknownServices =
          if isServiceStack stack && builtins.isList services
          then builtins.filter (service: !builtins.hasAttr service stack.serviceRegistry.services) services
          else [];
        mutations =
          [
            {
              domain = "serviceMoves";
              kind = "service-move";
              path = movePathFor scope transaction;
              inherit transaction;
            }
          ]
          ++ map (service: {
            domain = "servicePlacements";
            kind = "service-placement";
            path = placementPathFor scope service;
            inherit service;
          })
          sortedServices;
        result = {
          schema_version = 1;
          inherit mutations;
        };
      in
        assert require ((request.schema_version or null) == 1) "schema_version must be 1";
        assert require (builtins.hasAttr scope scopes) "scope must name a repository projection scope";
        assert require (isServiceStack stack) "scope must name a service stack";
        assert require (owner == scopes.${scope}.owner) "owner must match the scope repository owner";
        assert require (isName transaction) "transaction must be a safe repository component";
        assert require (builtins.isList services && services != [] && lib.all isName services) "services must be a non-empty list of safe repository components";
        assert require (builtins.length services == builtins.length (lib.unique services)) "services must be unique";
        assert require (unknownServices == []) "services are not declared in scope ${scope}: ${lib.concatStringsSep ", " unknownServices}";
          builtins.deepSeq result result;
  in {
    inherit movePathFor placementPathFor scopeCatalog scopes serviceMoveMutationsFor;
  };
in {
  inherit mkFamilyLayout mkRepository;
}
