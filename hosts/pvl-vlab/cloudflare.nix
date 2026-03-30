{
  config,
  lib,
  ...
}: let
  s = ../../data/secrets + "/cloudflare/tunnels/pvl-vlab-main.credentials.json.age";
  c =
    if builtins.pathExists s
    then
      builtins.path {
        path = s;
        name = "pvl-vlab-main.credentials.json.age";
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
    tunnels."22222222-2222-2222-2222-222222222222" = {
      credentialsFile = config.age.secrets.cloudflare-tunnel-main-credentials.path;
      default = "http_status:404";
      ingress = {
        "openwebui.example.com" = "http://127.0.0.1:13000";
      };
    };
  };
}
