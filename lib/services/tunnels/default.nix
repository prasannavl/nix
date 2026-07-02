{
  lib,
  stack ? null,
}: let
  cloudflare = import ./cloudflare.nix {inherit lib stack;};

  tunnelKinds = ["cloudflare" "rathole"];

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

  normalizeTunnel = tunnel:
    {
      name =
        if tunnel.name != null
        then tunnel.name
        else builtins.head tunnel.hostNames;
      targetPort = null;
      service = null;
      remotePort = null;
    }
    // tunnel;

  tunnelsForPortCfg = portCfg:
    map normalizeTunnel (portCfg.tunnels or []);

  endpointsFromPortCfg = {
    stackName,
    serviceName,
    portName,
    portCfg,
  }:
    lib.concatMap
    (tunnel:
      map (hostName: {
        inherit stackName serviceName portName hostName;
        inherit (tunnel) kind name remotePort;
        targetPort = targetPortFor tunnel portCfg;
        service = serviceFor tunnel portCfg;
      })
      tunnel.hostNames)
    (tunnelsForPortCfg portCfg);

  endpointsFromService = stackName: serviceName: service:
    lib.concatLists (
      lib.mapAttrsToList (
        portName: portCfg:
          endpointsFromPortCfg {
            inherit stackName serviceName portName portCfg;
          }
      )
      service.exposedPorts
    );

  endpointsFromInstancesForStack = stackName: instances:
    lib.concatLists (
      lib.mapAttrsToList (endpointsFromService stackName) instances
    );

  ingressFromEndpoints = kind: endpoints:
    lib.foldl' lib.recursiveUpdate {} (
      map (endpoint: {"${endpoint.hostName}" = endpoint.service;}) (
        builtins.filter (endpoint: endpoint.kind == kind) endpoints
      )
    );

  tunnelIdFor = tunnel:
    tunnel.id or null;

  credentialsStoreNameFor = tunnel:
    tunnel.credentialsStoreName or null;

  credentialsSecretPathFor = tunnel:
    tunnel.credentialsSecretPath or null;

  ageSecretNameFor = tunnel:
    tunnel.ageSecretName or null;

  ratholeConfigFor = tunnel:
    tunnel.rathole or tunnel;

  hostManagedTunnelEnabled = tunnel:
    if tunnel.kind == "cloudflare"
    then tunnelIdFor tunnel != null
    else if tunnel.kind == "rathole"
    then tunnel.enable or true
    else false;

  mkRatholeTunnel = {tunnel}: let
    rathole = ratholeConfigFor tunnel;
  in {
    services.rathole =
      {
        enable = true;
        role =
          rathole.role
          or (throw "rathole tunnel requires rathole.role or role");
        settings =
          rathole.settings
          or (throw "rathole tunnel requires rathole.settings or settings");
      }
      // lib.optionalAttrs (rathole ? package) {
        package = rathole.package;
      }
      // lib.optionalAttrs (rathole ? credentialsFile) {
        credentialsFile = rathole.credentialsFile;
      };

    services.migration-manager.managedUnits.system."rathole.service" = {};
  };
in {
  inherit tunnelKinds;
  inherit hostManagedTunnelEnabled;

  endpointsFromInstances = stackName: instances:
    endpointsFromInstancesForStack stackName instances;

  ingressFromEndpoints = ingressFromEndpoints;

  ingressFromInstances = {
    kind ? "cloudflare",
    stackName,
  }: instances:
    ingressFromEndpoints kind (endpointsFromInstancesForStack stackName instances);

  ingressByKindFromInstances = stackName: instances: let
    endpoints = endpointsFromInstancesForStack stackName instances;
  in
    lib.genAttrs tunnelKinds (kind: ingressFromEndpoints kind endpoints);

  mkHostManagedTunnel = {
    config,
    tunnel,
    ingress,
    edgeIPVersion ? null,
    defaultService ? "http_status:404",
    originRequest ? {},
  }:
    if tunnel.kind == "cloudflare"
    then
      cloudflare.mkHostManagedTunnel {
        inherit config ingress edgeIPVersion defaultService originRequest;
        tunnelId =
          if tunnelIdFor tunnel != null
          then tunnelIdFor tunnel
          else throw "cloudflare tunnel requires id";
        credentialsStoreName =
          if credentialsStoreNameFor tunnel != null
          then credentialsStoreNameFor tunnel
          else throw "cloudflare tunnel requires credentialsStoreName";
        credentialsSecretPath = credentialsSecretPathFor tunnel;
        ageSecretName = ageSecretNameFor tunnel;
      }
    else if tunnel.kind == "rathole"
    then mkRatholeTunnel {tunnel = tunnel;}
    else throw "unsupported tunnel kind ${tunnel.kind}";
}
