{
  ab,
  config,
  lib,
  stack,
  ...
}: let
  mkHostManagedTunnel = import ../common/host-managed-tunnel.nix {inherit ab config lib stack;};
  tunnelIngress = config.services.podman-compose-tunnel-projection.pvl.ingress.cloudflare;
in
  mkHostManagedTunnel {
    tunnel = {
      kind = "cloudflare";
      id = "00bbdab6-1509-479f-83cd-24375fc70835";
      credentialsStoreName = "prasannavl-main.json.age";
    };
    ingress = tunnelIngress;
    # Rivendell should not force IPv4-only Cloudflare edge connectivity.
    edgeIPVersion = "auto";
  }
