{
  config,
  lib,
  ...
}: let
  s = ../../data/secrets + "/cloudflare/tunnels/pvl-x2-main.credentials.json.age";
  c =
    if builtins.pathExists s
    then
      builtins.path {
        path = s;
        name = "pvl-x2-main.credentials.json.age";
      }
    else null;
in {
  age.secrets = lib.optionalAttrs (c != null) {
    cloudflare-tunnel-main-credentials = {
      file = c;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.cloudflared = lib.mkIf (c != null) {
    enable = true;
    tunnels."11111111-1111-1111-1111-111111111111" = {
      credentialsFile = config.age.secrets.cloudflare-tunnel-main-credentials.path;
      default = "http_status:404";
      ingress = {
        "memos.example.com" = "http://127.0.0.1:5230";
        "docmost.example.com" = "http://127.0.0.1:3000";
        "vaultwarden.example.com" = "http://127.0.0.1:2000";
      };
    };
  };
}
