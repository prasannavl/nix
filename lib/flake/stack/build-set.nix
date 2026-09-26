{
  definitions,
  registryFor,
  mkRegistryArgs,
  resolveDependencyEndpoint,
  mkProjection ? _args: {},
}: let
  serviceRegistryLib = import ../service-registry.nix;
  recursiveMerge = serviceRegistryLib.recursiveMerge;

  build = definition: let
    registry = registryFor definition;
    validateRoleOverrides = context: name: controls: overrides: let
      role = registry.roles.${name} or null;
      roleFields =
        if role == null
        then []
        else builtins.attrNames role;
      unknown = builtins.filter (
        field: !builtins.elem field (roleFields ++ controls)
      ) (builtins.attrNames overrides);
    in
      assert role != null || throw "${context} ${name} references an unknown registry role";
      assert unknown == [] || throw "${context} ${name} has unknown fields: ${builtins.concatStringsSep ", " unknown}"; overrides;

    resolveOwnedRoles = declarations:
      builtins.mapAttrs (
        name: overrides:
          recursiveMerge
          registry.roles.${name}
          (validateRoleOverrides "owned role" name ["endpoint"] overrides)
      )
      declarations;

    resolveDependencyRoles = declarations:
      builtins.mapAttrs (
        name: declaration: let
          owner = definitions.${declaration.stack};
          endpoint = resolveDependencyEndpoint {
            inherit declaration name owner definition registry;
          };
          validated = validateRoleOverrides "dependency role" name ["endpoint" "endpointGroup" "placement" "stack"] declaration;
          overrides =
            builtins.removeAttrs validated ["endpoint" "endpointGroup" "placement" "stack"]
            // {endpoint = endpoint;};
        in
          recursiveMerge registry.roles.${name} overrides
      )
      declarations;

    ownedRoles = resolveOwnedRoles definition.instances;
    dependencyRoles = resolveDependencyRoles (definition.dependencies or {});
    roles = ownedRoles // dependencyRoles;
    services = builtins.intersectAttrs roles registry.services;
    domainNames = definition.domainNames or (builtins.attrNames registry.domains);
    domains = builtins.listToAttrs (
      map (name: {
        name = name;
        value = registry.domains.${name};
      })
      domainNames
    );
    tunnelDomains =
      definition.tunnelDomainNames or (
        registry.tunnelDomains
        ++ map (name: registry.domains.${name}) (definition.extraTunnelDomainNames or [])
      );

    registryStack = let
      constructor = overrides:
        serviceRegistryLib.mkStackRegistry (
          registryArgs
          // overrides
          // {
            constructor = constructor;
            includePlacements = false;
          }
        );
      registryArgs = mkRegistryArgs {
        inherit
          constructor
          domains
          definition
          registry
          roles
          services
          tunnelDomains
          ;
      };
    in
      serviceRegistryLib.mkStackRegistry registryArgs;
    projectionFor = projectedDefinition:
      mkProjection {
        inherit
          dependencyRoles
          ownedRoles
          definitions
          registry
          ;
        definition = projectedDefinition;
      };
    placementFor = name: let
      endpoint = definition.endpointGroups.${name};
      projectedDefinition =
        definition
        // {
          activeEndpointGroup = name;
          network =
            (endpoint.network or definition.network)
            // {
              name =
                if endpoint ? network
                then endpoint.network.name or "${definition.stackName}-${name}"
                else definition.network.name or definition.stackName;
              nodeLabel = endpoint.nodeLabel or name;
              priority = definition.network.priority;
            };
        };
    in
      projectionFor projectedDefinition;
  in
    registryStack
    // projectionFor definition
    // {
      placements =
        builtins.mapAttrs (
          name: placement: placement // placementFor name
        )
        registryStack.placements;
    };
in
  builtins.mapAttrs (_stackName: build) definitions
