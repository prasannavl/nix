{
  lib,
  stack ? null,
}: let
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

      services.migration-manager.managedUnits.system = lib.optionalAttrs (credentials != null) {
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
