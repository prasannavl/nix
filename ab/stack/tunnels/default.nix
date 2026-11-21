let
  kinds = ["cloudflare" "rathole"];

  targetPortFor = tunnel: portCfg:
    if tunnel.targetPort != null
    then tunnel.targetPort
    else portCfg.port;

  serviceFor = tunnel: portCfg: let
    upstreamProtocol = portCfg.upstreamProtocol or "http";
    port = toString (targetPortFor tunnel portCfg);
  in
    if tunnel.service != null
    then tunnel.service
    else if upstreamProtocol == "tcp"
    then "tcp://127.0.0.1:${port}"
    else if upstreamProtocol == "udp"
    then throw "${tunnel.kind} tunnel metadata does not support generic UDP service targets"
    else "http://127.0.0.1:${port}";

  normalize = tunnel: let
    name = tunnel.name or null;
  in
    {
      name =
        if name != null
        then name
        else builtins.head tunnel.hostNames;
      targetPort = null;
      service = null;
      remotePort = null;
    }
    // tunnel;

  endpointsFromPort = {
    stackName,
    serviceName,
    portName,
    portCfg,
  }:
    builtins.concatMap
    (tunnel:
      map (hostName: {
        inherit stackName serviceName portName hostName;
        inherit (tunnel) kind name remotePort;
        targetPort = targetPortFor tunnel portCfg;
        service = serviceFor tunnel portCfg;
      })
      tunnel.hostNames)
    (map normalize (portCfg.tunnels or []));

  endpointsFromService = stackName: serviceName: service:
    builtins.concatLists (
      map
      (portName:
        endpointsFromPort {
          inherit stackName serviceName portName;
          portCfg = service.exposedPorts.${portName};
        })
      (builtins.attrNames service.exposedPorts)
    );

  endpointsFromInstances = stackName: instances:
    builtins.concatLists (
      map
      (serviceName: endpointsFromService stackName serviceName instances.${serviceName})
      (builtins.attrNames instances)
    );

  ingressFromEndpoints = kind: endpoints:
    builtins.foldl'
    (result: endpoint:
      if endpoint.kind == kind
      then result // {${endpoint.hostName} = endpoint.service;}
      else result)
    {}
    endpoints;

  ingressByKindFromInstances = stackName: instances: let
    endpoints = endpointsFromInstances stackName instances;
  in
    builtins.listToAttrs (
      map
      (kind: {
        name = kind;
        value = ingressFromEndpoints kind endpoints;
      })
      kinds
    );
in {
  inherit kinds endpointsFromInstances ingressFromEndpoints ingressByKindFromInstances;

  podman = {
    policy = {lib}:
      import ./podman-policy.nix {
        inherit kinds lib;
      };
    projection = {factProjection}:
      import ./podman-projection.nix {
        inherit factProjection;
        tunnels = {
          inherit kinds endpointsFromInstances ingressFromEndpoints;
        };
      };
  };

  ingressFromInstances = {
    kind ? "cloudflare",
    stackName,
  }: instances:
    ingressFromEndpoints kind (endpointsFromInstances stackName instances);
}
