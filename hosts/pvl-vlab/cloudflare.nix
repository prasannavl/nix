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
      id = "00bbdab6-1509-479f-83cd-24375fc70835";
      credentialsStoreName = "prasannavl-main.json.age";
    };
    ingress = tunnelIngress;
    # Rivendell should not force IPv4-only Cloudflare edge connectivity.
    edgeIPVersion = "auto";
  }
