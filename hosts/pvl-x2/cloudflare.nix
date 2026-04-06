{
  config,
  lib,
  ...
}: let
  tunnelsLib = import ../../lib/services/tunnels/cloudflare.nix {lib = lib;};
  tunnelId = "f052edf6-4bc4-41a5-bf0c-be7a7dd05f03";
  tunnelIngress = config.services.podmanCompose.pvl.cloudflareTunnelIngress;
in
  tunnelsLib.mkHostManagedTunnel {
    inherit config tunnelId;
    credentialsStoreName = "p7log-main.json.age";
    ingress =
      tunnelIngress
      // {
        "x.p7log.com" = "ssh://localhost:22";
      };
    # Allow both IPv4 and IPv6
    edgeIPVersion = "auto";
  }
