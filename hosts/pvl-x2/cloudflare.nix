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
