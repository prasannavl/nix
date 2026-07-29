{
  profiles,
  registryFor,
  mkRegistryArgs,
  resolveDependencyEndpoint,
  mkProjection ? _args: {},
}: let
  serviceRegistryLib = import ./service-registry.nix;
  recursiveMerge = serviceRegistryLib.recursiveMerge;

  build = profile: let
    registry = registryFor profile;

    resolveOwnedRoles = declarations:
      builtins.mapAttrs (
        name: overrides: recursiveMerge registry.roles.${name} overrides
      )
      declarations;

    resolveDependencyRoles = declarations:
      builtins.mapAttrs (
        name: declaration: let
          owner = profiles.${declaration.stack};
          endpoint = resolveDependencyEndpoint {
            inherit declaration name owner profile registry;
          };
          overrides =
            builtins.removeAttrs declaration ["stack"]
            // {endpoint = endpoint;};
        in
          recursiveMerge registry.roles.${name} overrides
      )
      declarations;

    ownedRoles = resolveOwnedRoles profile.instances;
    dependencyRoles = resolveDependencyRoles (profile.dependencies or {});
    roles = ownedRoles // dependencyRoles;
    services = builtins.intersectAttrs roles registry.services;
    domainNames = profile.domainNames or (builtins.attrNames registry.domains);
    domains = builtins.listToAttrs (
      map (name: {
        name = name;
        value = registry.domains.${name};
      })
      domainNames
    );
    tunnelDomains =
      profile.tunnelDomainNames or (
        registry.tunnelDomains
        ++ map (name: registry.domains.${name}) (profile.extraTunnelDomainNames or [])
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
          profile
          registry
          roles
          services
          tunnelDomains
          ;
      };
    in
      serviceRegistryLib.mkStackRegistry registryArgs;
  in
    registryStack
    // mkProjection {
      inherit
        dependencyRoles
        ownedRoles
        profile
        profiles
        registry
        ;
    };
in
  builtins.mapAttrs (_stackName: build) profiles
