rec {
  mkRoles = roleSpecs: builtins.mapAttrs (name: role: role // {inherit name;}) roleSpecs;

  mkDomains = domainHosts: builtins.mapAttrs (name: hosts: {inherit name hosts;}) domainHosts;

  domainHosts = domains: builtins.mapAttrs (_: domain: domain.hosts) domains;

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
      then {domain = spec.domain.name;}
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

  tunnelHosts = tunnelDomains: extraHosts:
    builtins.concatLists (map (domain: domain.hosts) tunnelDomains) ++ extraHosts;

  roleHosts = roles: builtins.mapAttrs (_: role: role.host) roles;

  roleOctets = roles: builtins.mapAttrs (_: role: role.octet) roles;

  mkServiceRegistry = {
    defaultEndpointSpecs,
    activeEndpointGroup ? "live",
    dnsEndpointGroups ? builtins.attrNames defaultEndpointSpecs,
    dnsRouteDomains,
    internalDomain,
    limits ? {},
    loopbackCidrs ? ["127.0.0.0/8"],
    domains ? {},
    tunnelDomains ? builtins.attrValues domains,
    roleEndpointOverrides ? {},
    roleHosts,
    roleOctets,
    serviceSpecs ? {},
    splitHorizonRole ? "proxy",
    trustedCidrs ? [],
  }: let
    domainHostMap = domainHosts domains;
    resolvedTunnelHosts = tunnelHosts tunnelDomains [];
    endpointSpecFor = role: group:
      defaultEndpointSpecs.${group}
      // (roleEndpointOverrides.${role}.${group} or {});

    mkEndpoint = group: spec: {
      project = spec.project;
      host = roleHosts.${spec.role};
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
        defaultEndpointSpecs;
    };

    roles = builtins.mapAttrs (role: _host: mkRole role) roleHosts;
    endpointForGroup = role: group: builtins.head roles.${role}.endpoints.${group};
    activeEndpoint = role: endpointForGroup role activeEndpointGroup;
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
              dnsEndpointGroups)
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
    serviceRegistry = {
      roles = roles;
      activeEndpointGroup = activeEndpointGroup;
      services = serviceSpecs;
      limits = limits;
      domains = domainHostMap;
      tunnelHosts = resolvedTunnelHosts;
      domainFor = group: builtins.head domainHostMap.${group};
      addressFor = role: (activeEndpoint role).address;
      endpointFor = activeEndpoint;
      endpointForGroup = endpointForGroup;
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
      portSpecFor = service: portName: (serviceRegistry.serviceFor service).ports.${portName};
      portFor = service: portName: (serviceRegistry.portSpecFor service portName).port;
      upstreamForService = service: portName: "${serviceRegistry.ipForService service}:${toString (serviceRegistry.portFor service portName)}";
      upstreamsForService = service: portName: [(serviceRegistry.upstreamForService service portName)];
      # Private URLs target the active internal service IP and named host port.
      urlPrivateFor = scheme: service: portName: "${scheme}://${serviceRegistry.upstreamForService service portName}";
      # Public URLs target the service's external domain and the default HTTPS port.
      urlPublicFor = service: "https://${serviceRegistry.domainFor (serviceRegistry.serviceFor service).domain}";
      dns = {
        resolverAddress = (activeEndpoint splitHorizonRole).address;
        routeDomains = dnsRouteDomains;
        loopbackCidrs = loopbackCidrs;
        trustedCidrs = trustedCidrs;
        trustedCidrsWithLoopback = loopbackCidrs ++ trustedCidrs;
        records = dnsRecords;
        hostsLines = dnsHostsLines;
        hostsText = builtins.concatStringsSep "\n" dnsHostsLines;
      };
    };
  in
    serviceRegistry;
}
