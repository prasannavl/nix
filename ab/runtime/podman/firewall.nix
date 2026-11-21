{
  config,
  lib,
  ...
}: let
  cfg = config.services.podman-compose;
  facts = config._ab.runtime.podman.facts;
  factProjection = import ./projection.nix {inherit lib;};

  factFor = stack: serviceName: service:
    factProjection.factFor {
      inherit facts stack serviceName service;
    };

  firewallEntries = lib.concatLists (
    lib.mapAttrsToList (
      _: stack:
        lib.concatLists (
          lib.mapAttrsToList (
            serviceName: service: let
              fact = factFor stack serviceName service;
              runtimePorts = lib.listToAttrs (
                map (port: lib.nameValuePair port.name port) fact.ports
              );
            in
              lib.concatLists (
                lib.mapAttrsToList (
                  portName: portCfg:
                    lib.optional (portCfg.openFirewall or false)
                    (runtimePorts.${portName}
                      or (throw "podman-compose projection: missing firewall runtime port ${fact.name}.${portName}"))
                )
                service.exposedPorts
              )
          )
          stack.instances
        )
    )
    cfg
  );

  firewallPortsFor = protocol:
    lib.unique (
      map (entry: entry.port) (
        builtins.filter (entry: builtins.elem protocol entry.protocols) firewallEntries
      )
    );
in {
  networking.firewall.allowedTCPPorts = firewallPortsFor "tcp";
  networking.firewall.allowedUDPPorts = firewallPortsFor "udp";
}
