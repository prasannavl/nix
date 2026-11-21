{
  cloudflare,
  lib,
  rathole,
}: let
  tunnelIdFor = tunnel: tunnel.id or null;
  credentialBaseName = credentialsStoreName: let
    withoutJsonAge = lib.removeSuffix ".json.age" credentialsStoreName;
    withoutAge = lib.removeSuffix ".age" credentialsStoreName;
  in
    if withoutJsonAge != credentialsStoreName
    then withoutJsonAge
    else withoutAge;
in {
  enabled = tunnel:
    if tunnel.kind == "cloudflare"
    then tunnelIdFor tunnel != null
    else if tunnel.kind == "rathole"
    then tunnel.enable or true
    else false;

  plan = {
    tunnel,
    ingress,
    edgeIPVersion ? null,
    defaultService ? "http_status:404",
    originRequest ? {},
  }:
    if tunnel.kind == "cloudflare"
    then let
      tunnelId = let
        value = tunnelIdFor tunnel;
      in
        if value != null
        then value
        else throw "cloudflare tunnel requires id";
      credentialsStoreName =
        tunnel.credentialsStoreName
        or (throw "cloudflare tunnel requires credentialsStoreName");
      baseName = credentialBaseName credentialsStoreName;
      ageSecretName = tunnel.ageSecretName or "cloudflare-tunnel-${baseName}-credentials";
      unitName = "cloudflared-tunnel-${tunnelId}";
    in {
      credential = {
        inherit ageSecretName credentialsStoreName;
        sourcePath = tunnel.credentialsSecretPath or null;
      };
      managedUnits = [
        {
          name = unitName;
          units = [
            {
              scope = "system";
              user = null;
              unit = "${unitName}.service";
            }
          ];
        }
      ];
      moduleForCredentials = credentialsFile:
        cloudflare.mkTunnel {
          inherit credentialsFile defaultService edgeIPVersion ingress originRequest tunnelId;
        };
    }
    else if tunnel.kind == "rathole"
    then {
      credential = null;
      managedUnits = [
        {
          name = "rathole";
          units = [
            {
              scope = "system";
              user = null;
              unit = "rathole.service";
            }
          ];
        }
      ];
      module = rathole.mkTunnel {inherit tunnel;};
    }
    else throw "unsupported tunnel kind ${tunnel.kind}";
}
