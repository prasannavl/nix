{lib}: let
  generatedServiceName = stack: serviceName: service:
    if service.serviceName != null
    then service.serviceName
    else "${stack.servicePrefix}${serviceName}";

  factFor = {
    facts,
    stack,
    serviceName,
    service,
  }:
    facts.${generatedServiceName stack serviceName service}
    or (throw "podman-compose projection: missing runtime facts for ${generatedServiceName stack serviceName service}");

  projectedInstances = {
    facts,
    stack,
  }:
    lib.mapAttrs (
      serviceName: service: let
        fact = factFor {
          inherit facts stack serviceName service;
        };
        runtimePorts = lib.listToAttrs (
          map (port: lib.nameValuePair port.name port) fact.ports
        );
      in
        service
        // {
          exposedPorts =
            lib.mapAttrs (
              portName: portCfg: let
                runtimePort =
                  runtimePorts.${portName}
                  or (throw "podman-compose projection: missing runtime port ${fact.name}.${portName}");
              in
                portCfg
                // {
                  inherit (runtimePort) port protocols;
                }
            )
            service.exposedPorts;
        }
    )
    stack.instances;
in {
  inherit factFor projectedInstances;
}
