{lib}: let
  tunnelPortFor = portCfg:
    if portCfg.cfTunnelPort != null
    then portCfg.cfTunnelPort
    else portCfg.port;

  ingressFromPortCfg = portCfg:
    lib.foldl' lib.recursiveUpdate {} (
      map
      (hostName: {"${hostName}" = "http://127.0.0.1:${toString (tunnelPortFor portCfg)}";})
      (portCfg.cfTunnelNames or [])
    );
in {
  ingressFromInstances = instances:
    lib.foldl' lib.recursiveUpdate {} (
      lib.concatMap
      (service: lib.mapAttrsToList (_: ingressFromPortCfg) service.exposedPorts)
      (builtins.attrValues instances)
    );
}
