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

  trackedPath = path: name:
    if builtins.pathExists path
    then
      builtins.path {
        path = path;
        name = name;
      }
    else null;

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
      else ../../../data/secrets + "/cloudflare/tunnels/${credentialsStoreName}";
    credentials = trackedPath resolvedCredentialsSecretPath credentialsStoreName;
  in {
    age.secrets = lib.optionalAttrs (credentials != null) {
      ${resolvedAgeSecretName} = {
        file = credentials;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };

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
  };
}
