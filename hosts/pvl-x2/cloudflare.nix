{
  config,
  lib,
  ...
}: let
  s = ../../data/secrets + "/cloudflare/tunnels/p7log-main.json.age";
  c =
    if builtins.pathExists s
    then
      builtins.path {
        path = s;
        name = "p7log-main.json.age";
      }
    else null;
  tunnelIngress = config.services.podmanCompose.pvl.cloudflareTunnelIngress;
in {
  age.secrets = lib.optionalAttrs (c != null) {
    p7log-main-credentials = {
      file = c;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.cloudflared = lib.mkIf (c != null) {
    enable = true;
    tunnels."f052edf6-4bc4-41a5-bf0c-be7a7dd05f03" = {
      credentialsFile = config.age.secrets.p7log-main-credentials.path;
      default = "http_status:404";
      ingress =
        tunnelIngress
        // {
          "x.p7log.com" = "ssh://localhost:22";
        };
    };
  };
}
