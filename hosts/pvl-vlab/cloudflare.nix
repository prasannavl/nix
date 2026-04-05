{
  config,
  lib,
  ...
}: let
  tunnelsLib = import ../../lib/services/tunnels/cloudflare.nix {lib = lib;};
  tunnelId = "00bbdab6-1509-479f-83cd-24375fc70835";
  tunnelIngress = config.services.podmanCompose.pvl.cloudflareTunnelIngress;
in
  tunnelsLib.mkHostManagedTunnel {
    inherit config tunnelId;
    credentialsStoreName = "prasannavl-main.json.age";
    ingress = tunnelIngress;
    # Rivendell should not force IPv4-only Cloudflare edge connectivity.
    edgeIPVersion = "auto";
  }
