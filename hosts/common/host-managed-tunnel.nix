{
  ab,
  config,
  lib,
  stack,
}: {
  tunnel,
  ingress,
  edgeIPVersion ? null,
  defaultService ? "http_status:404",
  originRequest ? {},
}: let
  managed = ab.runtime.network.tunnels.managed;
  plan = managed.plan {
    inherit defaultService edgeIPVersion ingress originRequest tunnel;
  };
  credential = plan.credential;
  credentialsPath =
    if credential == null
    then null
    else if credential.sourcePath != null
    then credential.sourcePath
    else ../../data/secrets + "/globals/cloudflare/tunnels/${credential.credentialsStoreName}";
  credentials =
    if credential == null
    then null
    else stack.secrets.tracked credentialsPath credential.credentialsStoreName;
  provider =
    if credential == null
    then plan.module
    else plan.moduleForCredentials config.age.secrets.${credential.ageSecretName}.path;
  hostAgentServices = builtins.listToAttrs (map (entry: {
      inherit (entry) name;
      value.units = entry.units;
    })
    plan.managedUnits);
  active = managed.enabled tunnel && (credential == null || credentials != null);
in
  lib.mkIf active (
    {
      services = lib.recursiveUpdate provider.services {
        abird-host-agent.services = hostAgentServices;
      };
    }
    // lib.optionalAttrs (credential != null) {
      age.secrets.${credential.ageSecretName} = {
        file = credentials;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    }
  )
