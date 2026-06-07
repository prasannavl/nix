{
  lib,
  stack ? null,
}: let
  tunnelPortFor = portCfg:
    if portCfg.cfTunnelPort != null
    then portCfg.cfTunnelPort
    else portCfg.port;

  tunnelServiceFor = portCfg: let
    upstreamProtocol = portCfg.upstreamProtocol or "http";
    port = toString (tunnelPortFor portCfg);
  in
    if upstreamProtocol == "tcp"
    then "tcp://127.0.0.1:${port}"
    else if upstreamProtocol == "udp"
    then throw "Cloudflare Tunnel ingress does not support generic UDP service targets for cfTunnelNames"
    else "http://127.0.0.1:${port}";

  ingressFromPortCfg = portCfg:
    lib.foldl' lib.recursiveUpdate {} (
      map (hostName: {"${hostName}" = tunnelServiceFor portCfg;}) (portCfg.cfTunnelNames or [])
    );

  trackedPath =
    if stack != null
    then stack.srv.trackedPath
    else throw "cloudflare tunnel helper mkHostManagedTunnel requires a stack profile";

  credentialBaseName = credentialsStoreName: let
    withoutJsonAge = lib.removeSuffix ".json.age" credentialsStoreName;
    withoutAge = lib.removeSuffix ".age" credentialsStoreName;
  in
    if withoutJsonAge != credentialsStoreName
    then withoutJsonAge
    else withoutAge;
in {
  ingressFromInstances = instances:
    lib.foldl' lib.recursiveUpdate {} (
      lib.concatMap
      (service: lib.mapAttrsToList (_: ingressFromPortCfg) service.exposedPorts)
      (builtins.attrValues instances)
    );

  mkHostManagedTunnel = {
    config,
    credentialsStoreName,
    tunnelId,
    ingress,
    ageSecretName ? null,
    credentialsSecretPath ? null,
    edgeIPVersion ? null,
    defaultService ? "http_status:404",
    originRequest ? {},
  }: let
    baseName = credentialBaseName credentialsStoreName;
    resolvedAgeSecretName =
      if ageSecretName != null
      then ageSecretName
      else "cloudflare-tunnel-${baseName}-credentials";
    resolvedCredentialsSecretPath =
      if credentialsSecretPath != null
      then credentialsSecretPath
      else ../../../data/secrets + "/globals/cloudflare/tunnels/${credentialsStoreName}";
    credentials = trackedPath resolvedCredentialsSecretPath credentialsStoreName;
    tunnelUnitName = "cloudflared-tunnel-${tunnelId}";
  in
    {
      services.cloudflared = lib.mkIf (credentials != null) {
        enable = true;
        tunnels.${tunnelId} =
          {
            credentialsFile = config.age.secrets.${resolvedAgeSecretName}.path;
            default = defaultService;
            ingress = ingress;
          }
          // lib.optionalAttrs (edgeIPVersion != null) {
            edgeIPVersion = edgeIPVersion;
          }
          // lib.optionalAttrs (originRequest != {}) {
            originRequest = originRequest;
          };
      };

      services.migrator.managedUnits.system = lib.optionalAttrs (credentials != null) {
        "${tunnelUnitName}.service" = {};
      };
    }
    // {
      age.secrets = lib.optionalAttrs (credentials != null) {
        ${resolvedAgeSecretName} = {
          file = credentials;
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };
    };
}
