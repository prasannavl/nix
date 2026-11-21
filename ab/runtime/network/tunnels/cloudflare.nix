{lib}: {
  mkTunnel = {
    credentialsFile,
    tunnelId,
    ingress,
    edgeIPVersion ? null,
    defaultService ? "http_status:404",
    originRequest ? {},
  }: {
    services.cloudflared = {
      enable = true;
      tunnels.${tunnelId} =
        {
          inherit credentialsFile ingress;
          default = defaultService;
        }
        // lib.optionalAttrs (edgeIPVersion != null) {
          inherit edgeIPVersion;
        }
        // lib.optionalAttrs (originRequest != {}) {
          inherit originRequest;
        };
    };
  };
}
