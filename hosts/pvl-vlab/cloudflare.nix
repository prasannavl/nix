{
  config,
  lib,
  ...
}: let
  s = ../../data/secrets + "/cloudflare/tunnels/prasannavl-main.json.age";
  c =
    if builtins.pathExists s
    then
      builtins.path {
        path = s;
        name = "prasannavl-main.json.age";
      }
    else null;
  tunnelIngress = config.services.podmanCompose.pvl.cloudflareTunnelIngress;
in {
  age.secrets = lib.optionalAttrs (c != null) {
    prasannavl-main-credentials = {
      file = c;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.cloudflared = lib.mkIf (c != null) {
    enable = true;
    tunnels."00bbdab6-1509-479f-83cd-24375fc70835" = {
      credentialsFile = config.age.secrets.prasannavl-main-credentials.path;
      default = "http_status:404";
      ingress = tunnelIngress;
    };
  };
}
