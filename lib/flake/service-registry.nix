{
  mkServiceRegistry = {
    defaultEndpointSpecs,
    dnsEndpointGroups ? builtins.attrNames defaultEndpointSpecs,
    dnsRouteDomains,
    internalDomain,
    limits ? {},
    publicHosts ? {},
    publicTunnelHosts ? builtins.concatLists (builtins.attrValues publicHosts),
    roleEndpointOverrides ? {},
    roleHosts,
    roleOctets,
    serviceSpecs ? {},
    splitHorizonRole ? "proxy",
    trustedCidrs ? [],
  }: let
    endpointSpecFor = role: group:
      defaultEndpointSpecs.${group}
      // (roleEndpointOverrides.${role}.${group} or {});

    mkEndpoint = spec: {
      site = spec.site;
      project = spec.project;
      host = roleHosts.${spec.role};
      address = spec.address or "10.10.${toString spec.subnetOctet}.${toString roleOctets.${spec.role}}";
      weight = spec.weight;
      nodeLabel = spec.nodeLabel or spec.site;
    };

    mkRole = role: {
      host = roleHosts.${role};
      internalName = "${role}.${internalDomain}";
      endpoints =
        builtins.mapAttrs
        (
          group: _spec: [
            (mkEndpoint ((endpointSpecFor role group) // {role = role;}))
          ]
        )
        defaultEndpointSpecs;
    };

    roles = builtins.mapAttrs (role: _host: mkRole role) roleHosts;
    activeEndpoint = role: builtins.head roles.${role}.endpoints.production;
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
    publicDnsRecords =
      map
      (name: {
        name = name;
        address = (activeEndpoint splitHorizonRole).address;
        kind = "split-horizon-public";
      })
      publicTunnelHosts;
    dnsRecords = roleDnsRecords ++ endpointDnsRecords ++ publicDnsRecords;
    dnsHostsLines = map (record: "${record.address} ${record.name}") dnsRecords;
    serviceRegistry = {
      roles = roles;
      services = serviceSpecs;
      limits = limits;
      publicHosts = publicHosts;
      publicTunnelHosts = publicTunnelHosts;
      publicHostFor = group: builtins.head publicHosts.${group};
      addressFor = role: (activeEndpoint role).address;
      endpointFor = activeEndpoint;
      upstreamFor = role: port: "${(activeEndpoint role).address}:${toString port}";
      upstreamsFor = role: port: [(serviceRegistry.upstreamFor role port)];
      serviceFor = service: serviceRegistry.services.${service};
      roleForService = service: (serviceRegistry.serviceFor service).role;
      endpointForService = service: activeEndpoint (serviceRegistry.roleForService service);
      ipForService = service: (serviceRegistry.endpointForService service).address;
      portSpecFor = service: portName: (serviceRegistry.serviceFor service).ports.${portName};
      portFor = service: portName: (serviceRegistry.portSpecFor service portName).port;
      upstreamForService = service: portName: "${serviceRegistry.ipForService service}:${toString (serviceRegistry.portFor service portName)}";
      upstreamsForService = service: portName: [(serviceRegistry.upstreamForService service portName)];
      urlPrivateFor = scheme: service: portName: "${scheme}://${serviceRegistry.upstreamForService service portName}";
      urlPublicFor = service: "https://${serviceRegistry.publicHostFor (serviceRegistry.serviceFor service).publicHostGroup}";
      dns = {
        resolverAddress = (activeEndpoint splitHorizonRole).address;
        routeDomains = dnsRouteDomains;
        trustedCidrs = trustedCidrs;
        records = dnsRecords;
        hostsLines = dnsHostsLines;
        hostsText = builtins.concatStringsSep "\n" dnsHostsLines;
      };
    };
  in
    serviceRegistry;
}
