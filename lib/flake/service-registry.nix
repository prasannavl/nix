rec {
  mkRoles = roles: builtins.mapAttrs (name: role: role // {inherit name;}) roles;

  mkDomains = domains: builtins.mapAttrs (name: hosts: {inherit name hosts;}) domains;

  hostsByDomain = domains: builtins.mapAttrs (_: domain: domain.hosts) domains;

  resolveExtraServices = extraServiceSpecs: args:
    if builtins.isFunction extraServiceSpecs
    then extraServiceSpecs args
    else extraServiceSpecs;

  mergeRoleServices = services: extraServices:
    builtins.mapAttrs (
      roleName: _:
        (services.${roleName} or {})
        // (extraServices.${roleName} or {})
    ) (services // extraServices);

  normalizeService = role: spec:
    builtins.removeAttrs spec ["domain"]
    // {
      role = role.name;
    }
    // (
      if spec ? domain
      then {
        domain =
          if builtins.isString spec.domain
          then spec.domain
          else spec.domain.name;
      }
      else {}
    );

  normalizeServices = roles: servicesByRole:
    builtins.foldl' (acc: roleServices: acc // roleServices) {} (
      builtins.attrValues (
        builtins.mapAttrs (
          roleName: specs:
            builtins.mapAttrs (_: normalizeService roles.${roleName}) specs
        )
        servicesByRole
      )
    );

  resolveDomainRef = domains: ref:
    if builtins.isString ref
    then domains.${ref} or {hosts = [ref];}
    else if builtins.isList ref
    then {hosts = ref;}
    else ref;

  resolveDomainRefs = domains: refs: map (resolveDomainRef domains) refs;

  tunnelHosts = tunnelDomains: builtins.concatLists (map (domain: domain.hosts) tunnelDomains);

  roleHosts = roles: builtins.mapAttrs (_: role: role.host) roles;

  roleOctets = roles: builtins.mapAttrs (_: role: role.octet) roles;

  roleEndpoints = roles:
    builtins.mapAttrs (_: role: role.endpoint or {}) roles;

  recursiveMerge = base: overrides:
    builtins.mapAttrs (
      name: value:
        if
          builtins.hasAttr name base
          && builtins.hasAttr name overrides
          && builtins.isAttrs base.${name}
          && builtins.isAttrs overrides.${name}
        then recursiveMerge base.${name} overrides.${name}
        else value
    ) (base // overrides);

  mkEndpointGroupStack = {
    stack,
    serviceRegistry,
    includePlacements ? true,
    constructor,
    constructorArgs,
    inactiveOverrides ? _endpointGroup: {},
  }:
    stack
    // (
      if includePlacements
      then {
        placements = serviceRegistry.mkPlacements {
          activePlacement = stack;
          mkPlacement = overrides:
            constructor (
              constructorArgs
              // overrides
              // {includePlacements = false;}
            );
          inactiveOverrides = inactiveOverrides;
        };
      }
      else {}
    );

  mkStackRegistry = args @ {
    constructor,
    stackName,
    org,
    env,
    activeEndpointGroup,
    localEndpointGroup ? activeEndpointGroup,
    endpointGroups,
    secretNamespace,
    secretScope ? null,
    domain,
    internalDomain,
    enableExternalConnectors,
    tunnels,
    dnsEndpointGroups ? builtins.attrNames endpointGroups,
    dnsRouteDomains ? ["~${internalDomain}" "~${domain}"],
    includePlacements ? true,
    extraRoles ? {},
    extraDomains ? {},
    extraServiceSpecs ? {},
    extraTunnelDomains ? [],
    roles,
    domains,
    services,
    tunnelDomains,
    limits,
    trustedCidrs,
    splitHorizonRole ? "proxy",
    stackBaseArgs,
    inactiveEndpointGroupOverrides ? _endpointGroup: {},
  }: let
    resolvedRoles = mkRoles (roles // extraRoles);
    resolvedDomains = mkDomains (domains // extraDomains);
    extraServices = resolveExtraServices extraServiceSpecs {
      domains = resolvedDomains;
      roles = resolvedRoles;
    };
    serviceSpecs = normalizeServices resolvedRoles (mergeRoleServices services extraServices);
    resolvedTunnelDomains = resolveDomainRefs resolvedDomains (tunnelDomains ++ extraTunnelDomains);

    serviceRegistry = mkServiceRegistry {
      inherit
        activeEndpointGroup
        endpointGroups
        limits
        localEndpointGroup
        serviceSpecs
        ;
      domains = resolvedDomains;
      tunnelDomains = resolvedTunnelDomains;
      dnsEndpointGroups = dnsEndpointGroups;
      dnsRouteDomains = dnsRouteDomains;
      internalDomain = internalDomain;
      roleHosts = roleHosts resolvedRoles;
      roleOctets = roleOctets resolvedRoles;
      roleEndpoints = roleEndpoints resolvedRoles;
      splitHorizonRole = splitHorizonRole;
      trustedCidrs = trustedCidrs;
    };

    withServiceRoles = roleOverrides: let
      unknownServices = builtins.filter (name: !(builtins.hasAttr name serviceSpecs)) (builtins.attrNames roleOverrides);
      unknownRoles = builtins.filter (role: !(builtins.hasAttr role resolvedRoles)) (builtins.attrValues roleOverrides);
      remappedServices =
        builtins.mapAttrs (
          name: spec:
            spec
            // {
              role = roleOverrides.${name} or spec.role;
            }
        )
        serviceSpecs;
      servicesByRole =
        builtins.mapAttrs (
          role: _:
            builtins.listToAttrs (
              map (
                name: {
                  inherit name;
                  value = builtins.removeAttrs remappedServices.${name} ["role"];
                }
              ) (builtins.filter (name: remappedServices.${name}.role == role) (builtins.attrNames remappedServices))
            )
        )
        resolvedRoles;
    in
      if unknownServices != []
      then throw "Unknown service role override(s): ${builtins.concatStringsSep ", " unknownServices}"
      else if unknownRoles != []
      then throw "Unknown target service role(s): ${builtins.concatStringsSep ", " unknownRoles}"
      else constructor {services = servicesByRole;};

    base = import ./stack/lib.nix (stackBaseArgs
      // {
        stackName = stackName;
        org = org;
        env = env;
        defaultMailDomain = stackBaseArgs.defaultMailDomain or domain;
        publicDomain = domain;
        internalDomain = internalDomain;
        secretScope = secretScope;
      });

    stack = base // {inherit enableExternalConnectors secretNamespace serviceRegistry tunnels withServiceRoles;};
    registryOnlyArgs = [
      "constructor"
      "roles"
      "domains"
      "services"
      "tunnelDomains"
      "limits"
      "trustedCidrs"
      "splitHorizonRole"
      "stackBaseArgs"
      "inactiveEndpointGroupOverrides"
      "org"
    ];
    constructorArgs = builtins.removeAttrs args registryOnlyArgs;
  in
    mkEndpointGroupStack {
      stack = stack;
      serviceRegistry = serviceRegistry;
      includePlacements = includePlacements;
      constructor = constructor;
      constructorArgs = constructorArgs;
      inactiveOverrides = endpointGroup: let
        endpointGroupData = endpointGroups.${endpointGroup};
      in
        {
          activeEndpointGroup = endpointGroupData.activeEndpointGroup or activeEndpointGroup;
          enableExternalConnectors = endpointGroupData.enableExternalConnectors or false;
          tunnels = recursiveMerge tunnels (endpointGroupData.tunnels or {});
        }
        // (inactiveEndpointGroupOverrides endpointGroup);
    };

  mkServiceRegistry = {
    endpointGroups,
    activeEndpointGroup ? "live",
    localEndpointGroup ? activeEndpointGroup,
    dnsEndpointGroups ? builtins.attrNames endpointGroups,
    dnsRouteDomains,
    internalDomain,
    limits ? {},
    loopbackCidrs ? ["127.0.0.0/8" "::1/128"],
    domains ? {},
    tunnelDomains ? builtins.attrValues domains,
    roleHosts,
    roleOctets,
    roleEndpoints ? {},
    serviceSpecs ? {},
    splitHorizonRole ? "proxy",
    trustedCidrs ? [],
  }: let
    cidrsByFamily = cidrs: {
      ipv4 = builtins.filter (cidr: builtins.match ".*:.*" cidr == null) cidrs;
      ipv6 = builtins.filter (cidr: builtins.match ".*:.*" cidr != null) cidrs;
    };
    loopbackCidrsByFamily = cidrsByFamily loopbackCidrs;
    trustedCidrsByFamily = cidrsByFamily trustedCidrs;
    trustedCidrsWithLoopback = loopbackCidrs ++ trustedCidrs;
    trustedCidrsWithLoopbackByFamily = cidrsByFamily trustedCidrsWithLoopback;
    filterAttrs = predicate: attrs:
      builtins.listToAttrs (
        builtins.concatMap (
          name:
            if predicate name attrs.${name}
            then [
              {
                inherit name;
                value = attrs.${name};
              }
            ]
            else []
        ) (builtins.attrNames attrs)
      );
    hostMap = hostsByDomain domains;
    resolvedTunnelHosts = tunnelHosts tunnelDomains;
    endpointGroupFor = group: builtins.removeAttrs endpointGroups.${group} ["activeEndpointGroup" "enableExternalConnectors" "memberRoles" "reservations" "roles" "tunnels"];
    hasExplicitRoleEndpoint = role:
      builtins.hasAttr role roleEndpoints
      && builtins.attrNames roleEndpoints.${role} != [];
    roleBelongsToGroup = role: group:
      hasExplicitRoleEndpoint role
      || !(endpointGroups.${group} ? memberRoles)
      || builtins.hasAttr role endpointGroups.${group}.roles;
    endpointSpecFor = role: group:
      (endpointGroupFor group)
      // (endpointGroups.${group}.roles.${role} or {})
      // (roleEndpoints.${role} or {});

    mkEndpoint = group: spec: {
      project = spec.project;
      host = spec.host or roleHosts.${spec.role};
      address = spec.address or "10.10.${toString spec.subnetOctet}.${toString roleOctets.${spec.role}}";
      weight = spec.weight;
      nodeLabel = spec.nodeLabel or group;
    };

    mkRole = role: {
      host = roleHosts.${role};
      internalName = "${role}.${internalDomain}";
      endpoints =
        builtins.mapAttrs
        (
          group: _spec: [
            (mkEndpoint group ((endpointSpecFor role group) // {role = role;}))
          ]
        )
        (filterAttrs (group: _spec: roleBelongsToGroup role group) endpointGroups);
    };

    roles = builtins.mapAttrs (role: _host: mkRole role) roleHosts;
    endpointForGroup = role: group: builtins.head roles.${role}.endpoints.${group};
    activeEndpoint = role: endpointForGroup role activeEndpointGroup;
    localEndpoint = role: endpointForGroup role localEndpointGroup;
    roleNames = builtins.attrNames roleHosts;
    roleDnsRecords =
      map
      (role: {
        name = roles.${role}.internalName;
        address = (activeEndpoint role).address;
        kind = "service";
      })
      roleNames;
    endpointDnsRecords =
      builtins.concatLists
      (map
        (
          role:
            builtins.concatLists
            (map
              (
                group:
                  map
                  (endpoint: {
                    name = "${endpoint.host}.${endpoint.nodeLabel}.${internalDomain}";
                    address = endpoint.address;
                    kind = "node";
                    role = role;
                    endpointGroup = group;
                  })
                  roles.${role}.endpoints.${group}
              )
              (builtins.filter (
                  group: builtins.hasAttr group roles.${role}.endpoints
                )
                dnsEndpointGroups))
        )
        roleNames);
    tunnelDnsRecords =
      map
      (name: {
        name = name;
        address = (activeEndpoint splitHorizonRole).address;
        kind = "split-horizon-domain";
      })
      resolvedTunnelHosts;
    dnsRecords = roleDnsRecords ++ endpointDnsRecords ++ tunnelDnsRecords;
    dnsHostsLines = map (record: "${record.address} ${record.name}") dnsRecords;
    activeResolverAddress = (activeEndpoint splitHorizonRole).address;
    localResolverAddress = (localEndpoint splitHorizonRole).address;
    serviceRegistry = {
      roles = roles;
      endpointGroups = endpointGroups;
      activeEndpointGroup = activeEndpointGroup;
      localEndpointGroup = localEndpointGroup;
      services = serviceSpecs;
      limits = limits;
      domains = hostMap;
      tunnelHosts = resolvedTunnelHosts;
      domainFor = group: builtins.head hostMap.${group};
      addressFor = role: (activeEndpoint role).address;
      endpointFor = activeEndpoint;
      localEndpointFor = localEndpoint;
      endpointForGroup = endpointForGroup;
      mkPlacements = {
        activePlacement,
        mkPlacement,
        inactiveOverrides ? _endpointGroup: {},
      }:
        builtins.mapAttrs (
          endpointGroup: _endpointSpec:
            if endpointGroup == activeEndpointGroup
            then activePlacement
            else
              mkPlacement (
                (inactiveOverrides endpointGroup)
                // {localEndpointGroup = endpointGroup;}
              )
        )
        endpointGroups;
      upstreamFor = role: port: "${(activeEndpoint role).address}:${toString port}";
      upstreamsFor = role: port: [(serviceRegistry.upstreamFor role port)];
      serviceFor = service: serviceRegistry.services.${service};
      roleForService = service: (serviceRegistry.serviceFor service).role;
      placementForService = service: (serviceRegistry.serviceFor service).placement or activeEndpointGroup;
      endpointForService = service: let
        spec = serviceRegistry.serviceFor service;
      in
        endpointForGroup spec.role (spec.placement or activeEndpointGroup);
      ipForService = service: (serviceRegistry.endpointForService service).address;
      servicesShareHost = client: service: let
        caller = serviceRegistry.endpointForService client;
        target = serviceRegistry.endpointForService service;
      in
        caller.project
        == target.project
        && caller.host == target.host
        && caller.address == target.address;
      # Named-port access policy owns both client routing and firewall sources.
      allowedClientsFor = service: portName: let
        clients = (serviceRegistry.portSpecFor service portName).allowedServices or [];
        unknown = builtins.filter (client: !(builtins.hasAttr client serviceSpecs)) clients;
      in
        if unknown != []
        then throw "Unknown client(s) for '${service}.${portName}': ${builtins.concatStringsSep ", " unknown}"
        else clients;
      clientEndpointForService = {
        client,
        service,
        portName,
      }: let
        caller = serviceRegistry.serviceFor client;
        localContainer = serviceRegistry.servicesShareHost client service && caller ? podmanSubnet;
      in
        if !(builtins.elem client (serviceRegistry.allowedClientsFor service portName))
        then throw "Service '${client}' is not allowed to call '${service}.${portName}'"
        else {
          host =
            if localContainer
            then "host.containers.internal"
            else serviceRegistry.ipForService service;
          port = serviceRegistry.portFor service portName;
        };
      allowedClientIpv4CidrsFor = service: portName: let
        sourceFor = client: let
          caller = serviceRegistry.serviceFor client;
          cidr =
            if serviceRegistry.servicesShareHost client service && caller ? podmanSubnet
            then caller.podmanSubnet
            else "${serviceRegistry.ipForService client}/32";
        in
          if builtins.match ".*:.*" cidr != null
          then throw "Service '${service}.${portName}' requires an IPv4 source for '${client}'"
          else cidr;
      in
        builtins.foldl' (cidrs: client: let
          cidr = sourceFor client;
        in
          if builtins.elem cidr cidrs
          then cidrs
          else cidrs ++ [cidr]) []
        (serviceRegistry.allowedClientsFor service portName);
      portSpecFor = service: portName: (serviceRegistry.serviceFor service).ports.${portName};
      portFor = service: portName: (serviceRegistry.portSpecFor service portName).port;
      upstreamForService = service: portName: "${serviceRegistry.ipForService service}:${toString (serviceRegistry.portFor service portName)}";
      upstreamsForService = service: portName: [(serviceRegistry.upstreamForService service portName)];
      # Private URLs target the active internal service IP and named host port.
      urlPrivateFor = scheme: service: portName: "${scheme}://${serviceRegistry.upstreamForService service portName}";
      # Public URLs target the service's external domain and the default HTTPS port.
      urlPublicFor = service: "https://${serviceRegistry.domainFor (serviceRegistry.serviceFor service).domain}";
      dns = {
        inherit activeResolverAddress localResolverAddress;
        resolverAddress = activeResolverAddress;
        routeDomains = dnsRouteDomains;
        loopbackCidrs = loopbackCidrs;
        trustedCidrs = trustedCidrs;
        inherit loopbackCidrsByFamily trustedCidrsByFamily trustedCidrsWithLoopback trustedCidrsWithLoopbackByFamily;
        records = dnsRecords;
        hostsLines = dnsHostsLines;
        hostsText = builtins.concatStringsSep "\n" dnsHostsLines;
      };
    };
  in
    serviceRegistry;
}
