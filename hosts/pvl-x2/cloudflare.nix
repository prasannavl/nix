{
  config,
  lib,
  stack,
  ...
}: let
  tunnelsLib = import ../../lib/services/tunnels {inherit lib stack;};
  tunnelIngress = config.services.podman-compose.pvl.tunnelIngress.cloudflare;
in
  tunnelsLib.mkHostManagedTunnel {
    inherit config;
    tunnel = {
      kind = "cloudflare";
      id = "f052edf6-4bc4-41a5-bf0c-be7a7dd05f03";
      credentialsStoreName = "p7log-main.json.age";
    };
    ingress =
      tunnelIngress
      // {
        "x.p7log.com" = "ssh://localhost:22";
      };
    # Allow both IPv4 and IPv6
    edgeIPVersion = "auto";
  }
